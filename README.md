# hello-gitops

Aplicação Flask "Hello World" para demonstração de pipeline GitOps + coleta de logs via OpenTelemetry Operator.

## Sobre a aplicação

Aplicação Python (Flask) minimalista, feita só para servir de "carga" na demo de
GitOps — sem banco de dados, sem dependências externas além das libs do
`requirements.txt`. Roda com Gunicorn em produção (definido no `Dockerfile`).

Ela não tem nenhuma lógica de negócio de verdade; o objetivo é dar suporte visual
para três coisas na demo:

- **Pipeline GitOps**: a rota `/` expõe a `APP_VERSION`, então dá pra mostrar
  visualmente quando o pipeline promove uma nova versão.
- **Observabilidade via OTel**: toda requisição gera uma linha de log em JSON no
  stdout, coletada automaticamente pelo OTel Collector; a rota `/error` existe só
  para gerar um log de erro proposital e demonstrar essa coleta.
- **Secrets via ESO**: a rota `/secret-check` confirma se o segredo vindo do
  ESO/Secrets Manager chegou até o Pod, mostrando apenas uma versão mascarada do
  valor (ex: `se****23`), sem expor o segredo real.

### Rotas

| Rota            | Método | Descrição |
|------------------|--------|-----------|
| `/`              | GET    | Retorna `{"message": "Hello, GitOps World!", "version": "<APP_VERSION>"}`. Gera um log de `INFO` a cada chamada. |
| `/health`        | GET    | Retorna `{"status": "ok"}` com HTTP 200. Usada pelo `readinessProbe` e `livenessProbe` do Deployment. |
| `/secret-check`  | GET    | Retorna `{"secret_loaded": true/false, "secret_preview": "se****23"}`. Confirma que o segredo sincronizado pelo ESO chegou ao Pod, sem expor o valor real (ver seção do ESO abaixo). |
| `/error`         | GET    | Retorna HTTP 500 de propósito e gera um log de `ERROR`. Serve para testar/demonstrar a coleta de logs de erro pelo OTel. |

### Variáveis de ambiente

| Variável              | Obrigatória | Descrição |
|-----------------------|-------------|-----------|
| `APP_VERSION`         | não (default `v1`) | Versão exibida na rota `/`. Útil para mostrar visualmente que uma nova versão foi promovida pelo pipeline GitOps. |
| `APP_SECRET_MESSAGE`  | não | Segredo consumido pela rota `/secret-check`, injetado via `secretKeyRef` a partir do Secret que o ESO sincroniza do AWS Secrets Manager (ver seção do ESO). Se ausente, `/secret-check` retorna `secret_loaded: false`. |

### Logs

O logging é configurado em `app.py` para escrever em **stdout**, em um formato JSON
simples (`time`, `level`, `msg`). Isso é proposital: o OTel Collector, com o receiver
de log de arquivo/stdout do container, consegue coletar essas linhas sem nenhuma
configuração extra na aplicação — não é necessário instalar um SDK de logging do
OTel no código. Quando a auto-instrumentação Python é injetada (annotation do
OTel Operator), a aplicação também passa a exportar traces via OTLP automaticamente.

O Gunicorn também é configurado (`--access-logfile - --error-logfile -`) para mandar
o access log dele para stdout, então cada requisição HTTP gera uma linha de log
adicional (fora as que a própria aplicação loga explicitamente).

### Rodando localmente sem Docker

```bash
pip install -r requirements.txt
APP_VERSION=local APP_SECRET_MESSAGE=teste123 python app.py
curl localhost:8080/
curl localhost:8080/secret-check
```

## Estrutura

```
app.py                  # app Flask com rotas / , /health , /secret-check , /error e logs estruturados em stdout
Dockerfile
requirements.txt
k8s/
  namespace.yaml
  instrumentation.yaml  # CR do OTel Operator (auto-instrumentation Python)
  serviceaccount.yaml   # SA usada pelo ESO para acessar o Secrets Manager (via EKS Pod Identity)
  secretstore.yaml      # SecretStore do ESO apontando para o AWS Secrets Manager
  externalsecret.yaml   # ExternalSecret que sincroniza o segredo do SM para um Secret k8s
  deployment.yaml       # consome o Secret via env + annotation do OTel Operator
  service.yaml
  kustomization.yaml
.github/workflows/ci.yaml  # build, push da imagem e commit da nova tag (fecha o loop GitOps)
```

## Fluxo da demo

1. **Pré-requisito no cluster**: OpenTelemetry Operator instalado e um OTel Collector rodando
   (ajuste o `endpoint` em `k8s/instrumentation.yaml` para apontar pro seu Collector).
2. **Build local (teste rápido, opcional)**:
   ```bash
   docker build -t hello-gitops:local .
   docker run -p 8080:8080 hello-gitops:local
   curl localhost:8080/
   ```
3. **Pipeline (CI)**: ao dar push em `app.py`/`Dockerfile`, o workflow builda a imagem,
   dá push no registry e **commita a nova tag** em `k8s/deployment.yaml`.
4. **GitOps (CD)**: aponte um `Application` do ArgoCD (ou `Kustomization` do Flux) para a
   pasta `k8s/` deste repo. Quando o CI commitar a nova tag, a ferramenta detecta a
   mudança no Git e sincroniza automaticamente no cluster — sem `kubectl apply` manual.
5. **Logs**: como o Pod sobe com a annotation do OTel Operator, o sidecar/init-container
   de auto-instrumentação é injetado e os logs (stdout, formato JSON simples) e traces
   são exportados via OTLP para o Collector configurado.
6. **Secret**: o ESO sincroniza o segredo do AWS Secrets Manager para um `Secret` nativo
   do cluster, que o Deployment consome como env var. Chame `GET /secret-check` para
   confirmar na demo que o valor chegou até o Pod (sem expor o segredo real).

## Sobre o External Secrets Operator (ESO)

A ideia aqui é nunca versionar o valor do segredo no Git — só a **referência** de onde
buscá-lo. Quem materializa o segredo dentro do cluster é o ESO, lendo do AWS Secrets
Manager (SM). Três peças novas em `k8s/`:

- **`serviceaccount.yaml`**: ServiceAccount `hello-gitops-sa` **sem nenhuma annotation
  de role** — a permissão IAM é concedida via **EKS Pod Identity**, não via IRSA
  (ver subseção abaixo). O manifest fica limpo, sem nenhuma informação sensível/de
  conta AWS.

- **`secretstore.yaml`**: o `SecretStore` diz ao ESO **como** e **onde** buscar o segredo
  (provider AWS, região). Também não tem bloco `auth` — as credenciais chegam
  automaticamente via Pod Identity, então não é preciso referenciar role nem
  service account explicitamente aqui.

- **`externalsecret.yaml`**: o `ExternalSecret` diz **qual** segredo buscar (`remoteRef.key`
  aponta para o path/nome no Secrets Manager) e **como materializá-lo** localmente —
  o ESO cria/atualiza automaticamente um `Secret` chamado `hello-gitops-secret` no
  namespace, com a chave `APP_SECRET_MESSAGE`. O `refreshInterval: 1h` faz o ESO
  reconsultar o SM periodicamente e atualizar o Secret se o valor mudar lá.

- No **`deployment.yaml`**, o container consome esse Secret normalmente via
  `env.valueFrom.secretKeyRef`, igual a qualquer Secret nativo do Kubernetes — a
  aplicação não sabe (nem precisa saber) que o valor veio do AWS Secrets Manager.

### Por que Pod Identity em vez de IRSA

Na primeira versão deste projeto, a ServiceAccount usava **IRSA**
(`eks.amazonaws.com/role-arn`), o que significa versionar o ARN da IAM Role — e
consequentemente o **Account ID da AWS** — direto no manifest, dentro do Git.

Com **EKS Pod Identity** (feature mais recente da AWS, similar ao conceito de task
role do ECS), a associação entre "esta ServiceAccount, neste namespace" e "esta IAM
Role" é feita **fora do repositório**, via AWS CLI, Console ou Terraform/IaC do time
de infra — nunca em um manifest do Kubernetes:

```bash
aws eks create-pod-identity-association \
  --cluster-name SEU_CLUSTER \
  --namespace hello-gitops \
  --service-account hello-gitops-sa \
  --role-arn arn:aws:iam::ACCOUNT_ID:role/hello-gitops-eso-role
```

Vantagens práticas disso para a demo/repo:
- **Nada sensível no Git**: `serviceaccount.yaml` e `secretstore.yaml` não citam
  Account ID nem ARN de role — só o nome da service account.
- **Reuso do manifest**: o mesmo `k8s/` funciona em clusters/contas diferentes
  (dev, staging, prod) sem precisar trocar nada no repositório — a role certa é
  vinculada por fora, por ambiente.
- **Menos acoplamento** entre quem mantém os manifests da aplicação e quem mantém
  a estrutura de IAM/contas da AWS.

Pré-requisito: o cluster precisa ter o add-on **`eks-pod-identity-agent`** instalado
(`aws eks create-addon --addon-name eks-pod-identity-agent --cluster-name SEU_CLUSTER`)
e o ESO em uma versão que suporte Pod Identity (v0.10+).


Fluxo ponta a ponta: **AWS Secrets Manager → ESO (via SecretStore + ExternalSecret) →
Secret nativo do k8s → env var no Pod → `os.getenv("APP_SECRET_MESSAGE")` no `app.py`**.

Para a demo, a rota `GET /secret-check` só informa se o segredo foi carregado (`true`/`false`)
e mostra uma versão mascarada do valor (ex: `se****23`) — suficiente pra provar visualmente
que o pipeline GitOps + ESO funcionou, sem expor o segredo de verdade em tela.

## Sobre o readiness e o liveness

No `k8s/deployment.yaml` o container tem dois probes configurados, ambos apontando
para a rota `/health` da aplicação:

```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 3
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 5
```

- **readinessProbe**: diz ao Kubernetes quando o Pod está **pronto para receber tráfego**.
  Enquanto o probe falha, o Pod é removido dos endpoints do Service (não recebe requisições),
  mas continua rodando normalmente. É usado, por exemplo, durante o boot da aplicação ou se
  ela ficar temporariamente sobrecarregada/indisponível para novas conexões. No deploy, o
  rollout só avança para o próximo Pod quando o readiness do anterior fica `true` — isso evita
  tirar do ar uma versão saudável antes da nova estar pronta.

- **livenessProbe**: diz ao Kubernetes se o Pod está **"vivo"/saudável**. Se esse probe falhar
  repetidamente, o kubelet **mata e reinicia o container** (não só remove do Service). Serve
  para casos em que a aplicação trava (deadlock, loop infinito, processo travado) mas o
  processo continua de pé sem responder — o restart resolve.

Diferenças práticas usadas aqui:
- `initialDelaySeconds` do liveness (5s) é maior que o do readiness (3s), dando um tempinho
  a mais antes de considerar reiniciar o container, já que a app é bem simples e sobe rápido.
- Ambos usam a mesma rota `/health` porque a app é um hello world sem dependências externas
  (banco, cache, etc). Em uma aplicação real, é comum o readiness verificar também
  dependências externas (ex: conexão com banco), enquanto o liveness costuma checar só se
  o processo/handler HTTP em si está respondendo — para não reiniciar o Pod por causa de uma
  dependência externa fora do ar.
- Para a demo de GitOps, os dois probes também são úteis para mostrar o comportamento de
  rollout do ArgoCD/Flux: se você quebrar a rota `/health` de propósito num commit, dá pra
  visualizar o Pod novo nunca ficando `Ready` e o rollout ficando "travado" — bom gancho para
  falar de estratégias de deploy (rolling update, rollback automático, etc).

## Ajustes que você precisa fazer antes de rodar

- Trocar `SEU_REGISTRY` no `Dockerfile`... (na verdade está em `k8s/deployment.yaml` e `.github/workflows/ci.yaml`) pelo seu registry real (ghcr.io, Docker Hub, ECR, etc).
- Trocar o `endpoint` em `k8s/instrumentation.yaml` pelo Service do seu OTel Collector.
- Configurar os secrets `REGISTRY_USER` / `REGISTRY_PASSWORD` no repositório (se usar GitHub Actions).
- Ter o **External Secrets Operator** instalado no cluster (`helm install external-secrets ...`).
- Ter o add-on **`eks-pod-identity-agent`** instalado no cluster EKS.
- Criar a IAM Role com permissão `secretsmanager:GetSecretValue` e associá-la à
  service account `hello-gitops-sa` via `aws eks create-pod-identity-association`
  (comando na seção "Por que Pod Identity em vez de IRSA" acima) — isso é feito
  fora do Git, não em nenhum manifest deste repositório.
- Ajustar a `region` em `k8s/secretstore.yaml` e o `remoteRef.key`/`property` em
  `k8s/externalsecret.yaml` para o nome/formato real do segredo no AWS Secrets Manager
  (por padrão espera um segredo JSON tipo `{"message": "..."}` no path `hello-gitops/app-secret`).
