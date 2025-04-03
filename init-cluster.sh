#!/bin/bash
set -e # Mata o pod em caso de erro crítico

CONFIG="/usr/local/etc/redis/redis.conf"
TEMP_CONFIG="/data/redis.conf"

# Copia o arquivo para um local temporário
cp $CONFIG $TEMP_CONFIG

REDIS_PASSWORD=123456

# Substitui o placeholder no arquivo temporário
sed -i "s/__REDIS_PASSWORD__/$REDIS_PASSWORD/g" $TEMP_CONFIG

# Usa o arquivo temporário para iniciar o Redis
redis-server $TEMP_CONFIG --daemonize yes
sleep 5

echo "Inicializando pod..." >&2

TOTAL_PODS=6
REPLICAS=1
REDIS_SERVICE_HOST="redis-service"

# Função: replica com base em role salva
maybe_become_replica() {
    echo "🔍 Iniciando verificação de role para $(hostname)..."

    echo "➡️  Buscando master salvo no Redis (cluster:replica_map)..."
    RAW_MASTER_ID=$(redis-cli -a "$REDIS_PASSWORD" hget cluster:replica_map "$(hostname)" 2>/dev/null || true)
    if echo "$RAW_MASTER_ID" | grep -Eq '^[a-f0-9]{40}$'; then
        MASTER_ID="$RAW_MASTER_ID"
    else
        echo "⚠️  MASTER_ID inválido ou Redis indisponível. Ignorando replicacao."
        MASTER_ID=""
    fi
    echo "📄 MASTER_ID encontrado: $MASTER_ID"

    echo "➡️  Obtendo node_id atual com cluster myid..."
    MY_ID=$(redis-cli -a "$REDIS_PASSWORD" cluster myid || true)
    echo "📄 MY_ID atual: $MY_ID"

    echo "➡️  Buscando informações sobre o nó no cluster..."
    MY_INFO=$(redis-cli -a "$REDIS_PASSWORD" cluster nodes | grep "$MY_ID" || true)
    echo "📄 MY_INFO:"
    echo "$MY_INFO"

    echo "➡️  Verificando se o nó está como master..."
    IS_MASTER=$(echo "$MY_INFO" | awk '{print $3}' | grep -c master)
    echo "📄 IS_MASTER: $IS_MASTER"

    echo "➡️  Verificando se o nó possui slots atribuídos..."
    HAS_SLOTS=$(echo "$MY_INFO" | grep -Eo '[0-9]+-[0-9]+' | wc -l)
    echo "📄 HAS_SLOTS: $HAS_SLOTS"

    if [ "$IS_MASTER" -eq 1 ] && [ "$HAS_SLOTS" -eq 0 ] && [ -n "$MASTER_ID" ]; then
        echo "✅ Condições atendidas: este nó está como master, sem slots e com master salvo."
        echo "🔁 Executando cluster replicate $MASTER_ID..."
        REPLICATE_RESULT=$(redis-cli -a "$REDIS_PASSWORD" cluster replicate "$MASTER_ID" 2>&1)
        echo "📄 Resultado do cluster replicate:"
        echo "$REPLICATE_RESULT"
    else
        echo "❌ Condições NÃO atendidas para replicação:"
        [ "$IS_MASTER" -ne 1 ] && echo "  - Este nó não está como master."
        [ "$HAS_SLOTS" -ne 0 ] && echo "  - Este nó já possui slots atribuídos."
        [ -z "$MASTER_ID" ] && echo "  - Nenhum master salvo encontrado no Redis."
        echo "🚫 Nenhuma replicação será executada."
    fi

    echo "🔚 Finalizando verificação de role para $(hostname)"
}

cluster_exists() {
    for i in $(seq 0 $((TOTAL_PODS - 1))); do
        echo "Verificando estado do cluster no redis-cluster-$i..."
        set +e # Ignora erros
        if redis-cli -a "$REDIS_PASSWORD" -h redis-cluster-$i.$REDIS_SERVICE_HOST cluster info | grep -q 'cluster_state:ok'; then
            return 0  # Cluster existe
        fi
        set -e # Reativa erros
        done
    return 1  # Cluster ainda não existe
}

join_cluster_with_meet() {
    for i in $(seq 0 $((TOTAL_PODS - 1))); do
        if [[ $(hostname) != "redis-cluster-$i" ]]; then
            peer_host="redis-cluster-$i.$REDIS_SERVICE_HOST"
            peer_ip=$(getent hosts "$peer_host" | awk '{ print $1 }')

            echo "Tentando CLUSTER MEET com $peer_host ($peer_ip)..."
            output=$(redis-cli -a "$REDIS_PASSWORD" cluster meet "$peer_ip" 6379 2>&1)

            if echo "$output" | grep -q OK; then
                echo "CLUSTER MEET com $peer_host bem-sucedido."
                return 0
            else
                echo "Falha ao tentar CLUSTER MEET com $peer_host. Saída: $output"
            fi
        fi
    done

    echo "Não foi possível realizar CLUSTER MEET com nenhum pod."
    return 1
}

restore_nodes_conf() {
    echo "Tentando restaurar nodes.conf para $(hostname) via outro nó do cluster..."
    sleep 15 # Tempo para o cluster rebalancear os nós
    for i in $(seq 0 $((TOTAL_PODS - 1))); do
        if [[ $(hostname) != "redis-cluster-$i" ]]; then
            peer_host="redis-cluster-$i.$REDIS_SERVICE_HOST"
            echo "➡️  Tentando via $peer_host..."

            OUTPUT=$(redis-cli -a "$REDIS_PASSWORD" -h "$peer_host" get "cluster:nodesconf:$(hostname)" 2>&1 | grep -v "Using a password with" || true)
            echo "📄 Resposta de $peer_host:"
            echo "$OUTPUT"

            if echo "$OUTPUT" | grep -q 'MOVED'; then
                REDIRECT_ADDR=$(echo "$OUTPUT" | grep MOVED | awk '{print $3}' | tr -d '[:space:]')
                REDIRECT_IP=$(echo "$REDIRECT_ADDR" | cut -d: -f1)
                echo "🔁 Redirecionado para $REDIRECT_IP, tentando novamente..."
                sleep 1
                OUTPUT=$(redis-cli -a "$REDIS_PASSWORD" -h "$REDIRECT_IP" get "cluster:nodesconf:$(hostname)" 2>&1 | grep -v "Using a password with" || true)
                echo "📄 Resposta de $REDIRECT_IP:"
                echo "$OUTPUT"
            fi

            if echo "$OUTPUT" | grep -q 'myself' && echo "$OUTPUT" | grep -q 'connected'; then
                echo "$OUTPUT" > /data/nodes.conf
                echo "✅ nodes.conf restaurado com sucesso via $peer_host"
                return 0
            else
                echo "⏳ Aguardando cluster entrar em estado estável..."
                sleep 2
            fi
        fi
    done

    echo "⚠️  Não foi possível recuperar nodes.conf de nenhum nó do cluster."
    exit 1
}

save_nodes_conf_to_redis() {
    set +e # Ignora erros
    echo "Verificando se nodes.conf está pronto para salvamento..."
    if [ -s /data/nodes.conf ] && grep -q 'myself' /data/nodes.conf && grep -q 'connected' /data/nodes.conf; then
        echo "✅ Salvando nodes.conf no Redis para $(hostname)..."
        echo "📝 Conteúdo a ser salvo:" && cat /data/nodes.conf

        ENCODED_CONF=$(base64 /data/nodes.conf)
        SAVE_RESULT=$(redis-cli -a "$REDIS_PASSWORD" -x set "cluster:nodesconf:$(hostname)" < /data/nodes.conf 2>&1 | grep -v "Using a password with")
        
        echo "📤 Resultado do salvamento (redis-cli):"
        echo "$SAVE_RESULT"
        GET_RESULT=""

        if echo "$SAVE_RESULT" | grep -q 'MOVED'; then
            REDIRECT_ADDR=$(echo "$SAVE_RESULT" | grep MOVED | awk '{print $3}' | tr -d '[:space:]')
            REDIRECT_IP=$(echo "$REDIRECT_ADDR" | cut -d: -f1)
            echo "🔁 Redirecionado para $REDIRECT_IP, tentando novamente..."
            sleep 1
            SAVE_RESULT=$(redis-cli -a "$REDIS_PASSWORD" -h "$REDIRECT_IP" -x set "cluster:nodesconf:$(hostname)" < /data/nodes.conf 2>&1)
            echo "📤 Resultado do salvamento no IP redirecionado:" && echo "$SAVE_RESULT"
            echo "🔍 Verificando valor salvo..."
            GET_RESULT=$(redis-cli -a "$REDIS_PASSWORD" -h "$REDIRECT_IP" get "cluster:nodesconf:$(hostname)" 2>&1 | grep -v "Using a password with")
            
        else
            echo "🔍 Verificando valor salvo..."
            GET_RESULT=$(redis-cli -a "$REDIS_PASSWORD" get "cluster:nodesconf:$(hostname)" 2>&1)
        fi

        echo "📥 Valor retornado do Redis:" && echo "$GET_RESULT"

    else
        echo "⚠️  nodes.conf ainda não está completo. Salvamento ignorado."
    fi
    set -e # Ignora erros
}

wait_until_cluster_ready() {
    echo "⏳ Aguardando cluster entrar em estado estável..."
    for attempt in {1..10}; do
        sleep 2
        if redis-cli -a "$REDIS_PASSWORD" cluster info | grep -q "cluster_state:ok"; then
            echo "✅ Cluster está pronto para uso."
            return 0
        fi
    done
    echo "❌ Timeout: cluster não entrou em estado estável após 10 tentativas."
    return 1
}

if cluster_exists; then
    echo "Cluster já existe." >&2
    echo "Conectando ao cluster..." >&2

    # Restaura nodes.conf salvo no Redis (se houver)
    restore_nodes_conf

    # Se nodes.conf foi restaurado corretamente, sobe direto o Redis
    if [ -s /data/nodes.conf ]; then
        echo "nodes.conf já existe. Subindo Redis em foreground..."
        redis-cli -a "$REDIS_PASSWORD" shutdown
        exec redis-server $TEMP_CONFIG
    fi

    set +e # Ignora erros
    if join_cluster_with_meet; then 
        echo "Conexão ao cluster bem-sucedida." >&2
        maybe_become_replica
    else
        echo "Falha ao conectar ao cluster." >&2
        exit 1
    fi
    set -e # Reativa erros

else
    echo "Cluster não existe. Checando se é o redis-cluster-0." >&2

    # Esse passo só é necessário pra automatizar o pipeline
    # A conta de serviço não tem permissão para criar o cluster via kubernetes
    # Se for o primeiro pod, cria o cluster
    if [[ $(hostname) == "redis-cluster-0" ]]; then
        echo "Criando cluster Redis..." >&2
        NODES=""
        for i in $(seq 0 $((TOTAL_PODS - 1))); do
            NODES="$NODES redis-cluster-$i.$REDIS_SERVICE_HOST:6379"
        done

        sleep 5

        output_create=$(redis-cli -a "$REDIS_PASSWORD" --cluster create $NODES --cluster-replicas $REPLICAS --cluster-yes)
        echo "Saída do comando 'redis-cli cluster create':" >&2
        echo "$output_create" >&2
    else
        echo "Pod $HOSTNAME não é o primeiro pod. Aguardando cluster ser criado..." >&2
        sleep 15
    fi
fi

# Salva nodes.conf apenas se estiver válido
wait_until_cluster_ready

# Executa salvamento do nodes.conf com redirecionamento
save_nodes_conf_to_redis

# Para Redis em background e reinicia em foreground
echo "Reiniciando pod..." >&2
redis-cli -a "$REDIS_PASSWORD" shutdown

echo "Aplicando config de servidor ao pod..." >&2
exec redis-server $TEMP_CONFIG