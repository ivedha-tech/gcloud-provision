## request
curl -X POST http://localhost:8080/provision \
  -H "Content-Type: application/json" \
  -d '{
    "script_url": "https://raw.githubusercontent.com/yourusername/yourrepo/main/gcloud-three-tier.sh",
    "args": []
  }'

## log stream
curl http://localhost:8080/logs/{job_id}
