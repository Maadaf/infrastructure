# Infraestrutura — Free Flow

Serviços de infraestrutura partilhados pelo simulador, Vehicle Tracker, Edge Uploader e pela
futura ingestão dos equipamentos: NATS JetStream e armazenamento S3 compatível via MinIO.

## Executar (só NATS + MinIO)

```powershell
docker compose up -d
docker compose ps
Invoke-RestMethod http://localhost:8222/healthz
Invoke-RestMethod http://localhost:9000/minio/health/live
```

Aplicações no host usam `nats://localhost:4222` e `http://localhost:9000`. No lab Compose
(`compose.lab.yaml`) os serviços falam entre si por DNS Docker (`nats://nats:4222`, etc.)
na rede `freeflow_default`.

Os dados persistem nos volumes `freeflow_*_nats-data` e `freeflow_*_minio-data`.

## Lab E2E (caminho feliz sem hardware)

Prova: **simulador → vehicle-tracker → edge-uploader → mock-central**.
Camera-gateway fica de fora (precisa de câmara). Rede alinhada: `freeflow_default`.

Requisitos: Docker Desktop; pastas irmãs em `SW/` (`simulador`, `vehicle-tracker`,
`edge-uploader`, `mock-central-api`).

```powershell
cd "D:\Tracevia Brasil\Free Flow\SW\infrastructure"
docker compose -f compose.lab.yaml up -d --build
.\lab\smoke.ps1
```

Ou num passo: `.\lab\smoke.ps1 -Up`

Critério de sucesso: o script imprime `OK E2E lab` quando `GET http://localhost:8090/v1/passages`
tem `count >= 1`.

Parar (sem apagar volumes):

```powershell
docker compose -f compose.lab.yaml down
```

Não usar `docker compose down -v` salvo se quiser apagar dados de lab.

## TLS e autenticação

Coloque `ca.crt`, `server.crt` e `server.key` em `secrets/tls`, preencha as quatro variáveis do
`.env.example` e execute:

```powershell
docker compose -f compose.yaml -f compose.secure.yaml up -d
```

Não use `docker compose down -v` salvo se pretender apagar definitivamente eventos e evidências.
