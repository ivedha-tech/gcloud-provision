## request
curl -X POST http://localhost:8080/provision \
  -H "Content-Type: application/json" \
  -d '{
    "script_url": "https://raw.githubusercontent.com/ivedha-tech/gcloud-provision/refs/heads/main/gcloud.sh",
    "args": []
  }'

## log stream
curl http://localhost:8080/logs/{job_id}
