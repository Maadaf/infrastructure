# Infraestrutura — Free Flow

Serviços de infraestrutura partilhados pelo simulador, Vehicle Tracker, Edge Uploader e pela
futura ingestão dos equipamentos: NATS JetStream e armazenamento S3 compatível via MinIO.

## Executar

```powershell
docker compose up -d
docker compose ps
Invoke-RestMethod http://localhost:8222/healthz
Invoke-RestMethod http://localhost:9000/minio/health/live
```

Aplicações no host usam `nats://localhost:4222` e `http://localhost:9000`. Aplicações nos
Composes dos projetos usam `nats://host.docker.internal:4222` e
`http://host.docker.internal:9000`.

Os dados persistem nos volumes `freeflow-infrastructure_nats-data` e
`freeflow-infrastructure_minio-data`.

## TLS e autenticação

Coloque `ca.crt`, `server.crt` e `server.key` em `secrets/tls`, preencha as quatro variáveis do
`.env.example` e execute:

```powershell
docker compose -f compose.yaml -f compose.secure.yaml up -d
```

Não use `docker compose down -v` salvo se pretender apagar definitivamente eventos e evidências.
