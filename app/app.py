"""
Persistent Volume Manager - Sample Flask API App
Demonstrates data persistence across pod restarts.
"""

from flask import Flask, request, jsonify, send_file
import os
import datetime
import signal
import sys

# Catch SIGINT (Ctrl+C) and SIGTERM (kubectl delete pod) for graceful shutdown
def handle_signal(sig, frame):
    print(f"[APP] Received signal {sig}. Shutting down gracefully...")
    sys.exit(0)

signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)

app = Flask(__name__)
DATA_FILE = "/data/messages.txt"

# Ensure /data exists (useful for local fallback, though K8s PV covers this)
os.makedirs("/data", exist_ok=True)
if not os.path.exists(DATA_FILE):
    with open(DATA_FILE, "w") as f:
        f.write("Welcome to the Persistent Volume Manager UI!\n")

@app.route("/")
def index():
    """Serve the frontend HTML UI."""
    return send_file("static/index.html")

@app.route("/messages", methods=["GET"])
def get_messages():
    """Return all stored messages from the persistent volume."""
    try:
        if os.path.exists(DATA_FILE):
            with open(DATA_FILE, "r") as f:
                messages = f.readlines()
            return jsonify([msg.strip() for msg in messages])
        return jsonify([])
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/messages", methods=["POST"])
def add_message():
    """Append a new message to the persistent volume."""
    try:
        data = request.json
        if not data or "text" not in data:
            return jsonify({"error": "No text provided"}), 400
            
        text = data["text"].strip()
        if not text:
            return jsonify({"error": "Empty message"}), 400
            
        # Add timestamp
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        entry = f"[{timestamp}] {text}\n"
        
        with open(DATA_FILE, "a") as f:
            f.write(entry)
            
        return jsonify({"success": True, "message": "Message saved to persistent storage"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == "__main__":
    # Run on 0.0.0.0 to allow external access within the Docker container
    app.run(host="0.0.0.0", port=5000)
