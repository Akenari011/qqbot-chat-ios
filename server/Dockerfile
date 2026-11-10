FROM python:3.12-slim
WORKDIR /app
COPY server/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY server/ /app/
RUN useradd --system --uid 10001 --create-home app && mkdir /data && chown app:app /data
USER app
ENV QQBOT_DB_PATH=/data/messages.sqlite3
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
