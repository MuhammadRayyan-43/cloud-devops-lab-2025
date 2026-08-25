from flask import Flask, jsonify
from prometheus_flask_exporter import PrometheusMetrics

app = Flask(__name__)
metrics = PrometheusMetrics(app)


@app.route("/")
def index():
    return jsonify(message="devops lab app", status="running")


@app.route("/health")
def health():
    return jsonify(status="ok")


def add(a, b):
    return a + b


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
