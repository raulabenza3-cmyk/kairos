services:
  - type: web
    name: kairos
    runtime: python
    plan: free
    buildCommand: echo ok
    startCommand: python app.py
    envVars:
      - key: PYTHON_VERSION
        value: 3.11.9
