import logging
import os
import sys
import time

from flask import Flask, jsonify

# Log estruturado em stdout -> o OTel Collector (via OTel Operator)
# coleta isso como log do container automaticamente.
logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}',
    stream=sys.stdout,
)
logger = logging.getLogger("hello-gitops")

app = Flask(__name__)

APP_VERSION = os.getenv("APP_VERSION", "v1")

# Segredo sincronizado no cluster pelo External Secrets Operator (ESO)
# a partir do AWS Secrets Manager, montado como env var no Deployment.
APP_SECRET_MESSAGE = os.getenv("APP_SECRET_MESSAGE")


def mask(value: str) -> str:
    """Mascara o valor do segredo pra exibir na demo sem vazar o conteúdo real."""
    if not value:
        return ""
    if len(value) <= 4:
        return "*" * len(value)
    return value[:2] + "*" * (len(value) - 4) + value[-2:]


@app.route("/")
def hello():
    logger.info(f"request recebida na rota / (version={APP_VERSION})")
    return jsonify(message="Hello, GitOps World!!!", version=APP_VERSION)


@app.route("/health")
def health():
    return jsonify(status="ok"), 200


@app.route("/secret-check")
def secret_check():
    # Rota só para demo: confirma que o segredo do ESO/Secrets Manager
    # chegou até o Pod, sem expor o valor real.
    loaded = APP_SECRET_MESSAGE is not None
    logger.info(f"checagem de segredo solicitada (loaded={loaded})")
    return jsonify(
        secret_loaded=loaded,
        secret_preview=mask(APP_SECRET_MESSAGE) if loaded else None,
    )


@app.route("/error")
def error():
    # rota só pra gerar log de erro e testar coleta
    logger.error("erro simulado para teste de observabilidade")
    return jsonify(error="algo deu errado (de propósito)"), 500


if __name__ == "__main__":
    logger.info(f"iniciando hello-gitops app version={APP_VERSION}")
    app.run(host="0.0.0.0", port=8080)
