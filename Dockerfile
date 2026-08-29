FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8080

# gunicorn escreve access log em stdout também (facilita a captura pelo OTel)
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
