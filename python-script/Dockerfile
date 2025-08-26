
FROM python:3.12-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the script
COPY generate_targets.py .

# The script will be run by the Kubernetes CronJob
ENTRYPOINT [ "python", "./generate_targets.py" ]