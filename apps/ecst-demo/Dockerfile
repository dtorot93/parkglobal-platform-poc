# Imagen única de los servicios de demostración (APP=tarifas|zonas|consumidor-c).
FROM python:3.13.17-slim
RUN pip install --no-cache-dir "confluent-kafka[avro,schemaregistry]==2.16.1" \
 && useradd --uid 10001 --create-home app
WORKDIR /app
# Copia de las versiones registradas de los contratos (la genera build.sh desde streams/*/*/schemas: una sola fuente).
COPY contracts/ /app/contracts/
COPY ecst_demo.py /app/
USER 10001
ENV PYTHONUNBUFFERED=1 DATA_DIR=/data
EXPOSE 8000
ENTRYPOINT ["python", "/app/ecst_demo.py"]
