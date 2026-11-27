# Infraestrutura — Free Flow

Serviços de infraestrutura partilhados pelo simulador, Vehicle Tracker, Edge Uploader e pela
futura ingestão dos equipamentos: NATS JetStream e armazenamento S3 compatível via MinIO.

## Up estável (ordem fixa)

1. Criar as redes Docker **uma vez** (ignorar erro se já existirem).
2. Subir o compose pretendido **sem** `-v`.
3. Esperar health (ou correr o smoke, que espera).
4. Parar com `down` **sem** `-v` para conservar NATS/MinIO/histórico.

```powershell
cd "D:\Tracevia Brasil\Free Flow\SW\infrastructure"
docker network create freeflow_default
docker network create freeflow_central
# se já existir: docker: Error ... already exists — OK, continuar
```

Não usar `docker compose down -v` salvo se quiser apagar eventos e evidências.

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

## Serviço central (API + BD + MinIO + ops-ui + simulador)

Stack separado do pórtico. O **simulador** (gémeo digital de lab) vive aqui e publica no
NATS/MinIO do pórtico via rede `freeflow_default`. Ver Project `docs/servico-central.md`.

```powershell
cd "D:\Tracevia Brasil\Free Flow\SW\infrastructure"
docker network create freeflow_default
docker network create freeflow_central
docker compose -f compose.central.yaml up -d --build
.\lab\smoke-central.ps1 -Up
```

Sucesso = `OK E2E central` com `evidence=s3://freeflow-central/...`.  
ops-ui: http://127.0.0.1:8089 · simulador API: http://127.0.0.1:8080

## Lab E2E (pórtico → central)

Prova: **simulador (central) → vehicle-tracker → edge-uploader → central-api**.  
`mock-central-api` foi retirado.

```powershell
cd "D:\Tracevia Brasil\Free Flow\SW\infrastructure"
docker network create freeflow_default
docker network create freeflow_central
docker compose -f compose.central.yaml up -d --build
docker compose -f compose.lab.yaml up -d --build
.\lab\smoke.ps1
```

Ou: `.\lab\smoke-central.ps1 -Up` / `.\lab\smoke.ps1 -Up`  
Parar:

```powershell
docker compose -f compose.lab.yaml down
docker compose -f compose.central.yaml down
```

Sucesso = linha `OK E2E` com `evidence=s3://freeflow-central/...` e `jpeg_bytes=...`.

## Demo quase-produção (auth)

Activa Bearer no simulador e no central-api; o edge-uploader usa o mesmo token (`CENTRAL_AUTH_TOKEN`).

```powershell
cd "D:\Tracevia Brasil\Free Flow\SW\infrastructure"
Copy-Item .env.demo.auth.example .env.demo.auth
# editar os tokens em .env.demo.auth
docker network create freeflow_default
docker network create freeflow_central
.\lab\smoke.ps1 -Up -Demo
```

Equivalente manual:

```powershell
docker compose -f compose.central.yaml -f compose.demo.yaml --env-file .env.demo.auth up -d --build
docker compose -f compose.lab.yaml --env-file .env.demo.auth up -d --build
.\lab\smoke.ps1 -Demo
```

## Stack completo (`compose.full.yaml`)

Base: NATS, MinIO, VT, edge-uploader → central, **5 gateways** (driver simulator).  
Simulador de tráfego E2E: `compose.central.yaml`. Hardware: `compose.full.hardware.env`.

```powershell
cd "D:\Tracevia Brasil\Free Flow\SW\infrastructure"
docker network create freeflow_default
docker network create freeflow_central
docker compose -f compose.central.yaml up -d --build
docker compose -f compose.full.yaml up -d --build
docker compose -f compose.full.yaml down
```

## TLS e autenticação (NATS + MinIO)

Coloque `ca.crt`, `server.crt` e `server.key` em `secrets/tls`, preencha as quatro variáveis do
`.env.example` e execute:

```powershell
docker compose -f compose.yaml -f compose.secure.yaml up -d
```

Isto é o perfil TLS da infra base; o overlay `compose.demo.yaml` cobre auth de API para demos
do lab/central sem exigir certificados.
