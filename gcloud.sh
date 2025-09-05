#!/bin/bash

# Three-Tier Web Application Deployment with Cloud Run
# Tier 1: Presentation Layer (Frontend - Cloud Run)
# Tier 2: Application Layer (Backend API - Cloud Run)
# Tier 3: Data Layer (Cloud SQL PostgreSQL + Redis)

set -e

# Configuration Variables
PROJECT_ID="my-webapp-project"
REGION="us-central1"
VPC_NAME="webapp-vpc"
SUBNET_NAME="webapp-subnet"
DB_INSTANCE_NAME="webapp-db"
DB_NAME="webapp_production"
DB_USER="webapp_user"
REDIS_INSTANCE_NAME="webapp-cache"
FRONTEND_SERVICE_NAME="webapp-frontend"
BACKEND_SERVICE_NAME="webapp-backend"
CONNECTOR_NAME="webapp-connector"
SERVICE_ACCOUNT_NAME="webapp-service-account"

echo "🚀 Starting Three-Tier Web Application Deployment with Cloud Run..."

# Step 1: Set up project and enable APIs
echo "📋 Setting up project and enabling APIs..."
gcloud config set project $PROJECT_ID
gcloud services enable run.googleapis.com \
    sqladmin.googleapis.com \
    redis.googleapis.com \
    cloudbuild.googleapis.com \
    secretmanager.googleapis.com \
    monitoring.googleapis.com \
    logging.googleapis.com \
    compute.googleapis.com \
    vpcaccess.googleapis.com \
    servicenetworking.googleapis.com

# Step 2: Create VPC and networking
echo "🌐 Creating VPC and networking infrastructure..."
gcloud compute networks create $VPC_NAME \
    --subnet-mode=custom \
    --bgp-routing-mode=regional

gcloud compute subnets create $SUBNET_NAME \
    --network=$VPC_NAME \
    --range=10.0.0.0/24 \
    --region=$REGION \
    --enable-private-ip-google-access

# Reserve IP range for private services
gcloud compute addresses create google-managed-services-$VPC_NAME \
    --global \
    --purpose=VPC_PEERING \
    --prefix-length=16 \
    --network=$VPC_NAME

# Create private connection for Cloud SQL
gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges=google-managed-services-$VPC_NAME \
    --network=$VPC_NAME

# Create VPC Connector for Cloud Run
echo "🔗 Creating VPC Connector..."
gcloud compute networks vpc-access connectors create $CONNECTOR_NAME \
    --region=$REGION \
    --subnet=$SUBNET_NAME \
    --subnet-project=$PROJECT_ID \
    --min-instances=2 \
    --max-instances=10 \
    --machine-type=e2-micro

# Step 3: Create service account
echo "👤 Creating service account..."
gcloud iam service-accounts create $SERVICE_ACCOUNT_NAME \
    --display-name="Web App Service Account"

# Grant necessary permissions
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/cloudsql.client"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/redis.editor"

# Step 4: Set up Cloud SQL (Data Tier)
echo "🗄️  Setting up Cloud SQL PostgreSQL database..."
DB_PASSWORD=$(openssl rand -base64 32)

gcloud sql instances create $DB_INSTANCE_NAME \
    --database-version=POSTGRES_14 \
    --tier=db-f1-micro \
    --region=$REGION \
    --network=$VPC_NAME \
    --no-assign-ip \
    --storage-type=SSD \
    --storage-size=20GB \
    --storage-auto-increase \
    --backup-start-time=03:00 \
    --maintenance-window-day=SUN \
    --maintenance-window-hour=04 \
    --deletion-protection

# Create database and user
gcloud sql databases create $DB_NAME --instance=$DB_INSTANCE_NAME
gcloud sql users create $DB_USER --instance=$DB_INSTANCE_NAME --password="$DB_PASSWORD"

# Step 5: Set up Redis (Caching Layer)
echo "🔴 Setting up Redis instance..."
gcloud redis instances create $REDIS_INSTANCE_NAME \
    --size=1 \
    --region=$REGION \
    --network=$VPC_NAME \
    --redis-version=redis_6_x \
    --tier=basic

# Step 6: Create secrets for database credentials
echo "🔐 Creating secrets..."
echo -n "$DB_PASSWORD" | gcloud secrets create db-password --data-file=-
echo -n "$PROJECT_ID:$REGION:$DB_INSTANCE_NAME" | gcloud secrets create db-connection-name --data-file=-
echo -n "$DB_USER" | gcloud secrets create db-user --data-file=-
echo -n "$DB_NAME" | gcloud secrets create db-name --data-file=-

# Get Redis host
REDIS_HOST=$(gcloud redis instances describe $REDIS_INSTANCE_NAME --region=$REGION --format='value(host)')
echo -n "$REDIS_HOST" | gcloud secrets create redis-host --data-file=-

# Step 7: Create Dockerfiles and build images
echo "🐳 Creating Docker images..."

# Backend API Dockerfile
mkdir -p backend-app
cat <<EOF > backend-app/Dockerfile
FROM node:18-alpine

WORKDIR /app

# Create package.json
COPY package*.json ./
RUN npm install

COPY . .

EXPOSE 8080

CMD ["node", "server.js"]
EOF

# Backend package.json
cat <<EOF > backend-app/package.json
{
  "name": "webapp-backend",
  "version": "1.0.0",
  "description": "Web App Backend API",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "pg": "^8.8.0",
    "redis": "^4.5.1",
    "cors": "^2.8.5",
    "helmet": "^6.0.1",
    "morgan": "^1.10.0"
  }
}
EOF

# Backend server.js
cat <<EOF > backend-app/server.js
const express = require('express');
const { Pool } = require('pg');
const redis = require('redis');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');

const app = express();
const PORT = process.env.PORT || 8080;

// Middleware
app.use(helmet());
app.use(cors());
app.use(morgan('combined'));
app.use(express.json());

// Database connection
const pool = new Pool({
  user: process.env.DB_USER,
  host: process.env.DB_HOST || '127.0.0.1',
  database: process.env.DB_NAME,
  password: process.env.DB_PASSWORD,
  port: 5432,
});

// Redis connection
let redisClient;
if (process.env.REDIS_HOST) {
  redisClient = redis.createClient({
    host: process.env.REDIS_HOST,
    port: 6379,
  });
  redisClient.connect();
}

// Health check endpoint
app.get('/health', async (req, res) => {
  try {
    const dbResult = await pool.query('SELECT NOW()');
    let redisStatus = 'not configured';
    
    if (redisClient) {
      await redisClient.ping();
      redisStatus = 'connected';
    }
    
    res.json({
      status: 'healthy',
      timestamp: new Date().toISOString(),
      database: 'connected',
      redis: redisStatus,
      version: '1.0.0'
    });
  } catch (error) {
    res.status(500).json({
      status: 'unhealthy',
      error: error.message
    });
  }
});

// API endpoints
app.get('/api/users', async (req, res) => {
  try {
    const result = await pool.query('SELECT id, username, email FROM users LIMIT 10');
    res.json(result.rows);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/users', async (req, res) => {
  const { username, email } = req.body;
  try {
    const result = await pool.query(
      'INSERT INTO users (username, email) VALUES ($1, $2) RETURNING *',
      [username, email]
    );
    res.status(201).json(result.rows[0]);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Cache example endpoint
app.get('/api/cache/:key', async (req, res) => {
  if (!redisClient) {
    return res.status(503).json({ error: 'Redis not configured' });
  }
  
  try {
    const value = await redisClient.get(req.params.key);
    res.json({ key: req.params.key, value });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/cache/:key', async (req, res) => {
  if (!redisClient) {
    return res.status(503).json({ error: 'Redis not configured' });
  }
  
  try {
    await redisClient.set(req.params.key, req.body.value, { EX: 3600 });
    res.json({ message: 'Cached successfully' });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.listen(PORT, () => {
  console.log(\`Backend server running on port \${PORT}\`);
});
EOF

# Frontend Dockerfile
mkdir -p frontend-app
cat <<EOF > frontend-app/Dockerfile
FROM nginx:alpine

# Copy custom nginx configuration
COPY nginx.conf /etc/nginx/nginx.conf
COPY default.conf /etc/nginx/conf.d/default.conf

# Copy static files
COPY index.html /usr/share/nginx/html/
COPY style.css /usr/share/nginx/html/
COPY app.js /usr/share/nginx/html/

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
EOF

# Frontend nginx.conf
cat <<EOF > frontend-app/nginx.conf
events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    sendfile on;
    keepalive_timeout 65;
    
    include /etc/nginx/conf.d/*.conf;
}
EOF

# Frontend default.conf
cat <<EOF > frontend-app/default.conf
upstream backend {
    server \${BACKEND_URL};
}

server {
    listen 8080;
    server_name _;
    
    root /usr/share/nginx/html;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ /index.html;
    }
    
    location /api/ {
        proxy_pass \${BACKEND_URL}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Frontend HTML
cat <<EOF > frontend-app/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Three-Tier Web App</title>
    <link rel="stylesheet" href="style.css">
</head>
<body>
    <div class="container">
        <h1>Three-Tier Web Application</h1>
        <div class="tier-info">
            <div class="tier">
                <h2>Presentation Layer</h2>
                <p>Cloud Run Frontend Service</p>
            </div>
            <div class="tier">
                <h2>Application Layer</h2>
                <p>Cloud Run Backend API</p>
                <button onclick="testAPI()">Test Backend API</button>
            </div>
            <div class="tier">
                <h2>Data Layer</h2>
                <p>Cloud SQL + Redis</p>
                <button onclick="testDatabase()">Test Database</button>
            </div>
        </div>
        <div id="results"></div>
    </div>
    <script src="app.js"></script>
</body>
</html>
EOF

# Frontend CSS
cat <<EOF > frontend-app/style.css
* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

body {
    font-family: 'Arial', sans-serif;
    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    min-height: 100vh;
    color: #333;
}

.container {
    max-width: 1200px;
    margin: 0 auto;
    padding: 2rem;
}

h1 {
    text-align: center;
    color: white;
    margin-bottom: 2rem;
    font-size: 2.5rem;
}

.tier-info {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
    gap: 2rem;
    margin-bottom: 2rem;
}

.tier {
    background: rgba(255, 255, 255, 0.9);
    padding: 2rem;
    border-radius: 10px;
    box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
    text-align: center;
}

.tier h2 {
    color: #667eea;
    margin-bottom: 1rem;
}

button {
    background: #667eea;
    color: white;
    border: none;
    padding: 0.8rem 1.5rem;
    border-radius: 5px;
    cursor: pointer;
    font-size: 1rem;
    margin-top: 1rem;
    transition: background 0.3s;
}

button:hover {
    background: #5a6fd8;
}

#results {
    background: rgba(255, 255, 255, 0.9);
    padding: 2rem;
    border-radius: 10px;
    box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
    min-height: 200px;
}
EOF

# Frontend JavaScript
cat <<EOF > frontend-app/app.js
const BACKEND_URL = window.location.origin;

async function testAPI() {
    const resultsDiv = document.getElementById('results');
    resultsDiv.innerHTML = '<p>Testing Backend API...</p>';
    
    try {
        const response = await fetch(\`\${BACKEND_URL}/health\`);
        const data = await response.json();
        
        resultsDiv.innerHTML = \`
            <h3>Backend API Response:</h3>
            <pre>\${JSON.stringify(data, null, 2)}</pre>
        \`;
    } catch (error) {
        resultsDiv.innerHTML = \`<p style="color: red;">Error: \${error.message}</p>\`;
    }
}

async function testDatabase() {
    const resultsDiv = document.getElementById('results');
    resultsDiv.innerHTML = '<p>Testing Database Connection...</p>';
    
    try {
        const response = await fetch(\`\${BACKEND_URL}/api/users\`);
        const data = await response.json();
        
        resultsDiv.innerHTML = \`
            <h3>Database Query Result:</h3>
            <pre>\${JSON.stringify(data, null, 2)}</pre>
        \`;
    } catch (error) {
        resultsDiv.innerHTML = \`<p style="color: red;">Error: \${error.message}</p>\`;
    }
}

// Load health status on page load
document.addEventListener('DOMContentLoaded', testAPI);
EOF

# Step 8: Build and deploy backend service
echo "🔧 Building and deploying backend service..."
cd backend-app

gcloud builds submit --tag gcr.io/$PROJECT_ID/$BACKEND_SERVICE_NAME

gcloud run deploy $BACKEND_SERVICE_NAME \
    --image gcr.io/$PROJECT_ID/$BACKEND_SERVICE_NAME \
    --platform managed \
    --region $REGION \
    --allow-unauthenticated \
    --service-account $SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com \
    --vpc-connector $CONNECTOR_NAME \
    --set-env-vars "DB_HOST=127.0.0.1,PORT=8080" \
    --set-secrets "DB_PASSWORD=db-password:latest,DB_USER=db-user:latest,DB_NAME=db-name:latest,REDIS_HOST=redis-host:latest" \
    --add-cloudsql-instances $PROJECT_ID:$REGION:$DB_INSTANCE_NAME \
    --memory 512Mi \
    --cpu 1 \
    --concurrency 100 \
    --max-instances 10 \
    --min-instances 1

cd ..

# Get backend URL
BACKEND_URL=$(gcloud run services describe $BACKEND_SERVICE_NAME --platform managed --region $REGION --format 'value(status.url)')

# Step 9: Build and deploy frontend service
echo "🎨 Building and deploying frontend service..."
cd frontend-app

# Replace backend URL in nginx config
sed -i "s|\${BACKEND_URL}|$BACKEND_URL|g" default.conf

gcloud builds submit --tag gcr.io/$PROJECT_ID/$FRONTEND_SERVICE_NAME

gcloud run deploy $FRONTEND_SERVICE_NAME \
    --image gcr.io/$PROJECT_ID/$FRONTEND_SERVICE_NAME \
    --platform managed \
    --region $REGION \
    --allow-unauthenticated \
    --port 8080 \
    --memory 256Mi \
    --cpu 1 \
    --concurrency 100 \
    --max-instances 5 \
    --min-instances 0

cd ..

# Step 10: Set up Cloud SQL database schema
echo "🗄️  Setting up database schema..."
gcloud sql connect $DB_INSTANCE_NAME --user=$DB_USER --database=$DB_NAME --quiet <<EOF
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO users (username, email) VALUES 
('john_doe', 'john@example.com'),
('jane_smith', 'jane@example.com'),
('admin_user', 'admin@example.com')
ON CONFLICT (username) DO NOTHING;
EOF

# Step 11: Set up monitoring and alerting
echo "📊 Setting up monitoring..."
gcloud alpha monitoring policies create --policy-from-file=<(cat <<EOF
{
  "displayName": "Cloud Run High Error Rate",
  "combiner": "OR",
  "conditions": [
    {
      "displayName": "Error rate too high",
      "conditionThreshold": {
        "filter": "resource.type=\"cloud_run_revision\" AND metric.type=\"run.googleapis.com/request_count\"",
        "comparison": "COMPARISON_GREATER_THAN",
        "thresholdValue": "10",
        "duration": "300s",
        "aggregations": [
          {
            "alignmentPeriod": "300s",
            "perSeriesAligner": "ALIGN_RATE"
          }
        ]
      }
    }
  ]
}
EOF
)

# Step 12: Create backup bucket and schedule
echo "💾 Setting up backups..."
gsutil mb gs://$PROJECT_ID-backups

# Create backup script
cat <<EOF | gcloud functions deploy db-backup-function \
    --runtime python39 \
    --trigger-topic backup-topic \
    --region $REGION \
    --source <(cat <<'EOL'
import subprocess
import os
from datetime import datetime

def backup_database(event, context):
    project_id = os.environ['GCP_PROJECT']
    instance_name = '$DB_INSTANCE_NAME'
    database_name = '$DB_NAME'
    bucket_name = f'{project_id}-backups'
    
    timestamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    backup_file = f'db-backup-{timestamp}.sql'
    
    # Export database
    cmd = [
        'gcloud', 'sql', 'export', 'sql',
        instance_name,
        f'gs://{bucket_name}/{backup_file}',
        '--database', database_name
    ]
    
    subprocess.run(cmd, check=True)
    print(f'Database backup completed: {backup_file}')
EOL
)

# Create Cloud Scheduler job for daily backups
gcloud scheduler jobs create pubsub db-backup-job \
    --schedule="0 2 * * *" \
    --topic=backup-topic \
    --message-body="backup" \
    --time-zone="UTC"

# Get service URLs
FRONTEND_URL=$(gcloud run services describe $FRONTEND_SERVICE_NAME --platform managed --region $REGION --format 'value(status.url)')
BACKEND_URL=$(gcloud run services describe $BACKEND_SERVICE_NAME --platform managed --region $REGION --format 'value(status.url)')

echo "✅ Deployment completed successfully!"
echo ""
echo "🌍 Service URLs:"
echo "Frontend: $FRONTEND_URL"
echo "Backend API: $BACKEND_URL"
echo ""
echo "🗄️  Database Information:"
gcloud sql instances describe $DB_INSTANCE_NAME --format="table(name,databaseVersion,state,ipAddresses[0].ipAddress)"
echo ""
echo "🔴 Redis Information:"
gcloud redis instances describe $REDIS_INSTANCE_NAME --region=$REGION --format="table(name,host,port,memorySizeGb,state)"
echo ""
echo "🧪 Test Commands:"
echo "# Test frontend:"
echo "curl -I $FRONTEND_URL"
echo ""
echo "# Test backend health:"
echo "curl -X GET $BACKEND_URL/health"
echo ""
echo "# Test database connection:"
echo "curl -X GET $BACKEND_URL/api/users"
echo ""
echo "# Test cache (set value):"
echo "curl -X POST $BACKEND_URL/api/cache/test-key -H 'Content-Type: application/json' -d '{\"value\":\"Hello from cache!\"}'"
echo ""
echo "# Test cache (get value):"
echo "curl -X GET $BACKEND_URL/api/cache/test-key"
echo ""
echo "# Load testing:"
echo "for i in {1..50}; do curl -s $FRONTEND_URL > /dev/null & done"
echo ""
echo "# Monitor logs:"
echo "gcloud logging read 'resource.type=\"cloud_run_revision\"' --limit=50 --format='table(timestamp,resource.labels.service_name,textPayload)'"
echo ""
echo "# Clean up (when done):"
echo "# gcloud run services delete $FRONTEND_SERVICE_NAME --region=$REGION --quiet"
echo "# gcloud run services delete $BACKEND_SERVICE_NAME --region=$REGION --quiet"
echo "# gcloud sql instances delete $DB_INSTANCE_NAME --quiet"
echo "# gcloud redis instances delete $REDIS_INSTANCE_NAME --region=$REGION --quiet"
