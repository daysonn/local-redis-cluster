# local-redis-cluster
Repositório para teste de implantação de cluster redis 


## Aplicando os recursos

Aplicando os arquivos YAML ao cluster:
```bash
kubectl create namespace redis-cluster
kubectl apply -f redis-configmap.yaml
kubectl apply -f redis-service.yaml
kubectl apply -f redis-statefulset.yaml
```

Para verificar se tudo está rodando corretamente:
```bash
kubectl get pods -n redis
kubectl get svc -n redis
```

## Criando o Cluster Redis

```bash
kubectl exec -it redis-cluster-0 -n redis-cluster -- redis-cli --cluster create     redis-cluster-0.redis-cluster:6379     redis-cluster-1.
redis-cluster:6379     redis-cluster-2.redis-cluster:6379     redis-cluster-3.redis-cluster:6379     redis-cluster-4.redis-cluster:6379     redis-cluster-5.redis-cluster:6379     --cluster-replicas 1 --cluster-yes
```

## Testando a Conexão

Crie um pod cliente com `redis-client-test.yaml` para testar a conexão. Ele precisa estar no mesmo namespace do cluster já criado.

```bash
kubectl apply -f redis-client.yaml
```

Entre no pod cliente:
```bash
kubectl exec -it redis-client -n redis -- redis-cli -c -h redis-cluster-0.redis-cluster
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
kubectl exec -it debug-pod -n redis -- sh
```

Agora, dentro do pod, você pode rodar os seguintes testes:
```bash
nslookup redis-cluster
```

```bash
ping -c 4 redis-cluster
```

* O hostname `redis-cluster` refere-se ao nome do serviço que endereça as requisições para o cluster. Esse nome que deve ser chamado na aplicação para resolver a conexão.