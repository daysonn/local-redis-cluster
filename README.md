# local-redis-cluster
Repositório para teste de implantação de cluster redis. Este documento cobre os passos necessários para rodar um Redis Cluster no Kubernetes com kind.

## Visão Geral dos Recursos YAML
Para criar um Redis Cluster sem usar Helm, você precisará definir os seguintes recursos:

1. ConfigMap – Para configurar o Redis Cluster.
2. Service (Headless) – Para permitir a descoberta dos pods do Redis.
3. StatefulSet – Para garantir que os pods mantenham a identidade e se comuniquem corretamente.
4. Pod com Cliente Redis – Para testar a conexão.

## Aplicando os recursos

Aplicando os arquivos YAML e criando o cluster:
```bash
kubectl create namespace redis-namespace
kubectl apply -f redis-configmap.yaml
kubectl apply -f redis-service.yaml
kubectl apply -f redis-statefulset.yaml
```

Para verificar se tudo está rodando corretamente:
```bash
kubectl get pods -n redis-namespace
kubectl get svc -n redis-namespace
```


## Testando a Conexão

Crie um pod cliente com `redis-client-test.yaml` para testar a conexão. Ele precisa estar no mesmo namespace do cluster já criado.

```bash
kubectl apply -f redis-client.yaml
```

Entre no pod cliente:
```bash
kubectl exec -it redis-client -n redis-cluster -- redis-cli -c -h redis-cluster-0.redis-cluster
```

Testando a inserção de dados:
```bash
set key1 "Hello Redis!"
get key1
```

Se funcionar, a saída será:
```bash
"Hello Redis!"
```

## Testando a Conexão com uma imagem curlimages/curl

Execute o comando para criar o pod de depuração:
```bash
kubectl apply -f debug-pod.yaml
```

Agora, entre no pod para testar a conexão com o Redis e outros serviços:
```bash
kubectl exec -it debug-pod -n redis-namespace -- sh
```

Agora, dentro do pod, você pode rodar os seguintes testes:
```bash
pip install redis
python
```

```bash
import redis

redis_client = redis.StrictRedis(
    host="redis-cluster",
    port=6379,
    password="sua_senha",
    decode_responses=True
)
```

* O hostname `redis-cluster` refere-se ao nome do serviço que endereça as requisições para o cluster. Esse nome que deve ser chamado de dentro do pod da aplicação e, então, o k8s resolve a conexão.

## Removendo o Cluster Redis
```bash
kubectl delete namespace redis-cluster
```