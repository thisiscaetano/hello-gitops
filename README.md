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

## Autenticação da pipeline via OIDC (sem secrets fixos)

O workflow `.github/workflows/ci.yaml` não usa usuário/senha estáticos para logar
no registry — ele assume uma IAM Role via **OIDC do GitHub Actions**, no mesmo
espírito do Pod Identity: nenhuma credencial de longa duração fica guardada como
secret do repositório.

Como funciona:
1. O GitHub emite, durante o job, um token OIDC de curta duração identificando
   o repositório/branch que está rodando.
2. O passo `aws-actions/configure-aws-credentials@v4` troca esse token por
   credenciais temporárias da AWS, assumindo a role indicada em `role-to-assume`.
   O ARN da role **não fica escrito no workflow** — vem do secret
   `${{ secrets.AWS_ROLE_ARN }}`, configurado em *Settings → Secrets and variables →
   Actions* do repositório. Como este repo é público (fins de demonstração), o ARN
   (que expõe o Account ID da AWS) não pode ficar visível no YAML versionado.
3. `aws-actions/amazon-ecr-login@v2` usa essas credenciais para autenticar no ECR
   e faz o `docker push` normalmente.

Vale notar: mesmo sendo um secret do GitHub, o ARN da role sozinho não seria
suficiente para alguém assumi-la — a **trust policy** da role (abaixo) já restringe
quem pode usá-la ao seu repositório/branch específico. O secret é uma camada extra
de cautela, não a única proteção.

Para isso funcionar, a IAM Role (referenciada pelo secret `AWS_ROLE_ARN`) precisa de
uma **trust policy** que só confia em tokens emitidos para este repositório
específico — evitando que qualquer outro repo do GitHub consiga assumi-la:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:SEU_ORG/SEU_REPO:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

E a role precisa de uma policy de permissão liberando push no ECR
(`ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`, `ecr:PutImage`,
`ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`).

Isso exige que o cluster/conta AWS já tenha o **provedor OIDC do GitHub**
registrado no IAM (`token.actions.githubusercontent.com`) — passo único por
conta, feito uma vez (Console AWS → IAM → Identity providers, ou Terraform).

## Scan de segurança no pipeline (Trivy)

A pipeline tem **dois scans** com o [Trivy](https://github.com/aquasecurity/trivy-action),
em pontos diferentes:

**1. Scan do código-fonte (`fs`)**, logo após o checkout — escaneia o
código e o `requirements.txt` em busca de:
- Dependências Python com **vulnerabilidades conhecidas (CVEs)**.
- Segredos/credenciais deixados acidentalmente no código (chave de API,
  token, senha hardcoded).
- Configurações inseguras em arquivos de infraestrutura (o Trivy também
  entende YAML de Kubernetes/Dockerfile).

```yaml
- name: Scan de segurança (Trivy)
  uses: aquasecurity/trivy-action@master
  with:
    scan-type: fs
    scan-ref: .
    severity: CRITICAL,HIGH
    exit-code: "0"
    format: table
```

Aqui `exit-code: "0"` faz o Trivy **reportar mas não falhar** a pipeline — o
resultado aparece no log em formato de tabela, sem travar o fluxo.

**2. Scan da imagem (`image`)**, depois do build/push — escaneia a imagem
Docker já publicada, cobrindo uma camada que o scan de código não vê: o
**SO base** (pacotes Debian/apt da imagem `python:3.12-slim`) e tudo que foi
instalado no `Dockerfile`.

```yaml
- name: Scan de segurança da imagem (Trivy)
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: ${{ env.IMAGE }}:${{ env.TAG }}
    severity: CRITICAL,HIGH
    exit-code: "1"
    format: table
```

Aqui `exit-code: "1"` já está configurado como **gate real**: se o Trivy achar
algo `CRITICAL` ou `HIGH` na imagem, o job **falha nesse passo**, e o passo
seguinte (atualizar `k8s/deployment.yaml` e commitar) **nunca roda** — ou seja,
uma imagem vulnerável nunca chega a virar um commit que o ArgoCD/Flux
sincronizaria no cluster. É a demonstração central de "shift-left security":
o problema é barrado dentro do CI, antes de tocar no fluxo de GitOps.

### Como forçar um erro para demonstrar a pipeline funcionando

A forma mais simples e visual: fixar no `requirements.txt` uma versão antiga
e conhecidamente vulnerável de alguma lib. Por exemplo, trocar:

```
flask==3.0.3
```
por uma versão bem antiga, tipo:
```
flask==0.12.2
```

Dá um `git commit` + `push` na `main` e acompanha o Actions rodando: o segundo
step (scan de código) provavelmente já vai listar CVEs no log; mas o ponto
mais visual de "pipeline bloqueando" é depois do build — o step **"Scan de
segurança da imagem (Trivy)"** vai listar os CVEs em vermelho na tabela e o
job vai falhar com X vermelho, e o passo de atualizar o manifest fica cinza
("skipped"), mostrando claramente que o deploy foi barrado.

Depois da demo, é só reverter o `requirements.txt` para `flask==3.0.3` e dar
push de novo — a pipeline volta a passar normalmente.

Outra opção, pra mostrar a detecção de **segredo vazado** (não vulnerabilidade
de dependência): adicionar temporariamente uma linha óbvia em algum arquivo,
por exemplo em `app.py`:
```python
AWS_SECRET_ACCESS_KEY = "AKIAABCDEFGHIJKLMNOP"  # linha só para demo
```
O primeiro scan (`fs`, na etapa de código) deve sinalizar isso como segredo
exposto no log — mesmo com `exit-code: "0"` nessa etapa, o achado aparece
destacado na tabela, bom para mostrar a detecção sem precisar quebrar o
pipeline. Lembre de remover essa linha depois (nunca commitar de verdade).

## Ajustes que você precisa fazer antes de rodar

- Criar a IAM Role com a trust policy e as permissões de ECR descritas acima
  (seção "Autenticação da pipeline via OIDC"), trocando `ACCOUNT_ID`/`SEU_ORG`/`SEU_REPO`
  pelos valores reais da sua conta AWS e repositório GitHub.
- Configurar o secret **`AWS_ROLE_ARN`** em *Settings → Secrets and variables →
  Actions* do repositório, com o ARN dessa role. Nunca colar o ARN direto no
  `.github/workflows/ci.yaml` — o repo é público.
- Trocar `ECR_REPOSITORY`/`AWS_REGION` em `.github/workflows/ci.yaml` se usar outro
  nome de repositório ECR ou região.
- Trocar o `endpoint` em `k8s/instrumentation.yaml` pelo Service do seu OTel Collector.
- Ter o **External Secrets Operator** instalado no cluster (`helm install external-secrets ...`).
- Ter o add-on **`eks-pod-identity-agent`** instalado no cluster EKS.
- Criar a IAM Role com permissão `secretsmanager:GetSecretValue` e associá-la à
  service account `hello-gitops-sa` via `aws eks create-pod-identity-association`
  (comando na seção "Por que Pod Identity em vez de IRSA" acima) — isso é feito
  fora do Git, não em nenhum manifest deste repositório.
- Ajustar a `region` em `k8s/secretstore.yaml` e o `remoteRef.key`/`property` em
  `k8s/externalsecret.yaml` para o nome/formato real do segredo no AWS Secrets Manager
  (por padrão espera um segredo JSON tipo `{"message": "..."}` no path `hello-gitops/app-secret`).