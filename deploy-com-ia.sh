#!/bin/bash

# =============================================================================
# deploy-com-ia.sh — Deploy e Rollback para ECS do projeto BIA
# =============================================================================

set -euo pipefail

# ─── Configurações ────────────────────────────────────────────────────────────
REGIAO="us-east-1"
ECR_REPO_NAME="bia"
CONTAINER_NAME="bia"
WAIT_TIMEOUT=600  # 10 minutos

# Cores para output
VERMELHO='\033[0;31m'
VERDE='\033[0;32m'
AMARELO='\033[1;33m'
AZUL='\033[0;34m'
NEGRITO='\033[1m'
RESET='\033[0m'

# ─── Funções utilitárias ──────────────────────────────────────────────────────

log_info()    { echo -e "${AZUL}[INFO]${RESET} $1"; }
log_ok()      { echo -e "${VERDE}[OK]${RESET} $1"; }
log_warn()    { echo -e "${AMARELO}[AVISO]${RESET} $1"; }
log_erro()    { echo -e "${VERMELHO}[ERRO]${RESET} $1"; }
log_titulo()  { echo -e "\n${NEGRITO}${AZUL}══════════════════════════════════════${RESET}"; echo -e "${NEGRITO}${AZUL}  $1${RESET}"; echo -e "${NEGRITO}${AZUL}══════════════════════════════════════${RESET}\n"; }

confirmar() {
  local mensagem="$1"
  echo -e "${AMARELO}$mensagem [s/N]:${RESET} \c"
  read -r resposta
  [[ "$resposta" =~ ^[sS]$ ]]
}

escolher_ambiente() {
  echo ""
  echo -e "${NEGRITO}Selecione o ambiente:${RESET}"
  echo "  [1] Sem ALB  (cluster-bia / service-bia / task-def-bia)"
  echo "  [2] Com ALB  (cluster-bia-alb / service-bia-alb / task-def-bia-alb)"
  echo ""
  echo -e "Opção: \c"
  read -r opcao_amb

  case "$opcao_amb" in
    1)
      CLUSTER="cluster-bia"
      SERVICE="service-bia"
      TASK_DEF="task-def-bia"
      AMBIENTE_LABEL="Sem ALB"
      ;;
    2)
      CLUSTER="cluster-bia-alb"
      SERVICE="service-bia-alb"
      TASK_DEF="task-def-bia-alb"
      AMBIENTE_LABEL="Com ALB"
      ;;
    *)
      log_erro "Opção inválida. Abortando."
      return 1
      ;;
  esac

  log_info "Ambiente selecionado: ${NEGRITO}$AMBIENTE_LABEL${RESET}"
  log_info "  Cluster:         $CLUSTER"
  log_info "  Service:         $SERVICE"
  log_info "  Task Definition: $TASK_DEF"
}

buscar_ecr_uri() {
  log_info "Buscando URI do repositório ECR '$ECR_REPO_NAME'..."
  ECR_URI=$(aws ecr describe-repositories \
    --repository-names "$ECR_REPO_NAME" \
    --region "$REGIAO" \
    --query "repositories[0].repositoryUri" \
    --output text 2>/dev/null) || {
      log_erro "Repositório ECR '$ECR_REPO_NAME' não encontrado na região $REGIAO."
      return 1
    }
  log_ok "ECR URI: $ECR_URI"
}

login_ecr() {
  local ecr_registry
  ecr_registry=$(echo "$ECR_URI" | cut -d'/' -f1)
  log_info "Autenticando no ECR ($ecr_registry)..."
  aws ecr get-login-password --region "$REGIAO" \
    | docker login --username AWS --password-stdin "$ecr_registry" > /dev/null 2>&1
  log_ok "Login no ECR realizado com sucesso."
}

aguardar_estabilizacao() {
  local cluster="$1"
  local service="$2"
  log_info "Aguardando estabilização do serviço (timeout: ${WAIT_TIMEOUT}s)..."
  log_warn "Isso pode levar alguns minutos..."

  if aws ecs wait services-stable \
    --cluster "$cluster" \
    --services "$service" \
    --region "$REGIAO" \
    2>/dev/null; then
    log_ok "Serviço estabilizado com sucesso!"
  else
    log_erro "Timeout ou falha ao aguardar estabilização do serviço."
    log_warn "Verifique o status manualmente:"
    echo "  aws ecs describe-services --cluster $cluster --services $service --region $REGIAO"
    return 1
  fi
}

# ─── Fluxo de Deploy ──────────────────────────────────────────────────────────

fazer_deploy() {
  log_titulo "DEPLOY — Projeto BIA"

  # 1. Escolher ambiente
  escolher_ambiente || return 1

  # 2. Capturar short commit hash
  if ! git -C "$(dirname "$0")" rev-parse --git-dir > /dev/null 2>&1; then
    log_erro "Este diretório não é um repositório Git."
    return 1
  fi
  COMMIT_HASH=$(git -C "$(dirname "$0")" rev-parse --short HEAD)
  log_info "Commit hash: ${NEGRITO}$COMMIT_HASH${RESET}"

  # 3. Buscar URI do ECR
  buscar_ecr_uri || return 1

  # 4. Montar tag da imagem
  IMAGE_TAG="${ECR_URI}:${COMMIT_HASH}"
  log_info "Imagem que será gerada: ${NEGRITO}$IMAGE_TAG${RESET}"

  # 5. Confirmar antes de prosseguir
  echo ""
  confirmar "Deseja prosseguir com o build e deploy?" || {
    log_warn "Deploy cancelado pelo usuário."
    return 0
  }

  # 6. Login no ECR
  login_ecr || return 1

  # 7. Build da imagem
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  log_info "Iniciando build da imagem Docker..."
  docker build -t "$IMAGE_TAG" "$SCRIPT_DIR" || {
    log_erro "Falha no build da imagem Docker."
    return 1
  }
  log_ok "Build concluído: $IMAGE_TAG"

  # 8. Push da imagem para o ECR (tag do commit + tag latest)
  log_info "Fazendo push da imagem para o ECR..."
  docker push "$IMAGE_TAG" || {
    log_erro "Falha no push da imagem para o ECR."
    return 1
  }
  log_ok "Push concluído: $IMAGE_TAG"

  LATEST_TAG="${ECR_URI}:latest"
  log_info "Aplicando tag latest e fazendo push..."
  docker tag "$IMAGE_TAG" "$LATEST_TAG"
  docker push "$LATEST_TAG" || {
    log_erro "Falha no push da tag latest para o ECR."
    return 1
  }
  log_ok "Push concluído: $LATEST_TAG"

  # 9. Buscar task definition atual e gerar novo JSON
  log_info "Buscando task definition atual: $TASK_DEF..."
  TASK_DEF_JSON=$(aws ecs describe-task-definition \
    --task-definition "$TASK_DEF" \
    --region "$REGIAO" \
    --query "taskDefinition" \
    --output json 2>/dev/null) || {
      log_erro "Não foi possível buscar a task definition '$TASK_DEF'."
      return 1
    }

  # 10. Gerar novo JSON substituindo apenas a imagem do container
  log_info "Registrando nova revisão da task definition com a nova imagem..."
  NOVO_TASK_DEF_JSON=$(echo "$TASK_DEF_JSON" | jq \
    --arg img "$IMAGE_TAG" \
    --arg container "$CONTAINER_NAME" \
    '
    .containerDefinitions |= map(
      if .name == $container then .image = $img else . end
    ) |
    del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
        .compatibilities, .registeredAt, .registeredBy, .deregisteredAt)
    ')

  # 11. Registrar nova revisão
  NOVA_REVISAO=$(aws ecs register-task-definition \
    --region "$REGIAO" \
    --cli-input-json "$NOVO_TASK_DEF_JSON" \
    --query "taskDefinition.revision" \
    --output text) || {
      log_erro "Falha ao registrar nova task definition."
      return 1
    }
  log_ok "Nova revisão registrada: ${NEGRITO}${TASK_DEF}:${NOVA_REVISAO}${RESET}"

  # 12. Atualizar o service
  log_info "Atualizando o service ECS para usar ${TASK_DEF}:${NOVA_REVISAO}..."
  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "${TASK_DEF}:${NOVA_REVISAO}" \
    --region "$REGIAO" \
    --force-new-deployment \
    --output text > /dev/null || {
      log_erro "Falha ao atualizar o service ECS."
      return 1
    }
  log_ok "Service atualizado."

  # 13. Aguardar estabilização
  aguardar_estabilizacao "$CLUSTER" "$SERVICE" || return 1

  echo ""
  log_ok "${NEGRITO}Deploy concluído com sucesso!${RESET}"
  echo -e "  Ambiente:    $AMBIENTE_LABEL"
  echo -e "  Imagem:      $IMAGE_TAG"
  echo -e "  Task Def:    ${TASK_DEF}:${NOVA_REVISAO}"
  exit 0
}

# ─── Fluxo de Rollback ────────────────────────────────────────────────────────

fazer_rollback() {
  log_titulo "ROLLBACK — Projeto BIA"

  # 1. Escolher ambiente
  escolher_ambiente || return 1

  # 2. Buscar revisões da task definition
  log_info "Buscando revisões disponíveis para '$TASK_DEF'..."

  REVISOES=$(aws ecs list-task-definitions \
    --family-prefix "$TASK_DEF" \
    --status ACTIVE \
    --sort DESC \
    --region "$REGIAO" \
    --query "taskDefinitionArns[]" \
    --output json 2>/dev/null) || {
      log_erro "Não foi possível listar as revisões de '$TASK_DEF'."
      return 1
    }

  TOTAL=$(echo "$REVISOES" | jq 'length')
  if [[ "$TOTAL" -eq 0 ]]; then
    log_erro "Nenhuma revisão encontrada para '$TASK_DEF'."
    return 1
  fi

  # 3. Exibir tabela de revisões
  echo ""
  echo -e "${NEGRITO}Revisões disponíveis para ${TASK_DEF}:${RESET}"
  echo ""
  printf "  %-4s  %-8s  %-45s  %s\n" "Nº" "Revisão" "Imagem" "Registrada em"
  echo "  ────  ────────  ─────────────────────────────────────────────  ────────────────────"

  declare -A MAPA_REVISOES
  INDICE=1

  while IFS= read -r arn; do
    REVISAO_NUM=$(echo "$arn" | awk -F':' '{print $NF}')
    DETALHES=$(aws ecs describe-task-definition \
      --task-definition "$arn" \
      --region "$REGIAO" \
      --query "taskDefinition" \
      --output json 2>/dev/null)

    IMAGEM=$(echo "$DETALHES" | jq -r \
      --arg c "$CONTAINER_NAME" \
      '.containerDefinitions[] | select(.name == $c) | .image' 2>/dev/null || echo "N/A")

    # Extrair apenas a tag da imagem para exibição resumida
    IMAGEM_TAG=$(echo "$IMAGEM" | awk -F':' '{print $NF}')
    IMAGEM_RESUMIDA=$(echo "$IMAGEM" | sed 's|.*/||')  # remove o registry prefix

    DATA_REG=$(echo "$DETALHES" | jq -r '.registeredAt // "N/A"' | cut -c1-19 | tr 'T' ' ')

    printf "  %-4s  %-8s  %-45s  %s\n" "[$INDICE]" "$REVISAO_NUM" "$IMAGEM_RESUMIDA" "$DATA_REG"

    MAPA_REVISOES[$INDICE]="${TASK_DEF}:${REVISAO_NUM}"
    INDICE=$((INDICE + 1))
  done < <(echo "$REVISOES" | jq -r '.[]')

  echo ""

  # 4. Verificar revisão ativa no service
  REVISAO_ATIVA=$(aws ecs describe-services \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --region "$REGIAO" \
    --query "services[0].taskDefinition" \
    --output text 2>/dev/null | awk -F':' '{print $NF}')
  log_info "Revisão atualmente ativa no service: ${NEGRITO}${REVISAO_ATIVA}${RESET}"
  echo ""

  # 5. Solicitar escolha
  echo -e "Digite o número da revisão para rollback (1-$((INDICE-1))): \c"
  read -r escolha

  if [[ -z "${MAPA_REVISOES[$escolha]+_}" ]]; then
    log_erro "Opção inválida: '$escolha'. Abortando."
    return 1
  fi

  TASK_DEF_ESCOLHIDA="${MAPA_REVISOES[$escolha]}"
  REVISAO_ESCOLHIDA=$(echo "$TASK_DEF_ESCOLHIDA" | awk -F':' '{print $NF}')

  if [[ "$REVISAO_ESCOLHIDA" == "$REVISAO_ATIVA" ]]; then
    log_warn "A revisão escolhida ($REVISAO_ESCOLHIDA) já está ativa no service."
    confirmar "Deseja forçar o rollback mesmo assim?" || {
      log_warn "Rollback cancelado."
      return 0
    }
  fi

  echo ""
  confirmar "Confirma rollback para ${NEGRITO}$TASK_DEF_ESCOLHIDA${RESET}?" || {
    log_warn "Rollback cancelado pelo usuário."
    return 0
  }

  # 6. Atualizar o service
  log_info "Aplicando rollback para $TASK_DEF_ESCOLHIDA..."
  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "$TASK_DEF_ESCOLHIDA" \
    --region "$REGIAO" \
    --force-new-deployment \
    --output text > /dev/null || {
      log_erro "Falha ao atualizar o service ECS."
      return 1
    }
  log_ok "Service atualizado para $TASK_DEF_ESCOLHIDA."

  # 7. Aguardar estabilização
  aguardar_estabilizacao "$CLUSTER" "$SERVICE" || return 1

  echo ""
  log_ok "${NEGRITO}Rollback concluído com sucesso!${RESET}"
  echo -e "  Ambiente:  $AMBIENTE_LABEL"
  echo -e "  Task Def:  $TASK_DEF_ESCOLHIDA"
  exit 0
}

# ─── Menu Principal ───────────────────────────────────────────────────────────

menu_principal() {
  while true; do
    echo ""
    echo -e "${NEGRITO}╔══════════════════════════════════════╗${RESET}"
    echo -e "${NEGRITO}║     BIA — Deploy & Rollback ECS      ║${RESET}"
    echo -e "${NEGRITO}╚══════════════════════════════════════╝${RESET}"
    echo ""
    echo "  [1] Deploy"
    echo "  [2] Rollback"
    echo "  [3] Sair"
    echo ""
    echo -e "Opção: \c"
    read -r opcao

    case "$opcao" in
      1) fazer_deploy ;;
      2) fazer_rollback ;;
      3)
        echo ""
        log_ok "Saindo. Até logo!"
        exit 0
        ;;
      *)
        log_erro "Opção inválida. Tente novamente."
        ;;
    esac
  done
}

# ─── Verificações de pré-requisitos ──────────────────────────────────────────

verificar_prerequisitos() {
  local faltando=0

  for cmd in aws docker git jq; do
    if ! command -v "$cmd" &> /dev/null; then
      log_erro "Comando não encontrado: $cmd"
      faltando=1
    fi
  done

  if [[ "$faltando" -eq 1 ]]; then
    log_erro "Instale os pré-requisitos acima antes de continuar."
    exit 1
  fi
}

# ─── Entrypoint ───────────────────────────────────────────────────────────────

verificar_prerequisitos
menu_principal
