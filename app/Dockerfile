FROM python:3.12-slim

WORKDIR /app
# dependencies first: this layer is cached until requirements.txt changes
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY jobbot.py sources.py ./

# never run as root inside the container
USER 10001
EXPOSE 8000
CMD ["python", "-u", "jobbot.py"]
