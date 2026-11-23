apiVersion: v1
kind: Namespace
metadata:
  name: webapp
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: webapp-sa
  namespace: webapp
  annotations:
    eks.amazonaws.com/role-arn: "${APP_ROLE_ARN}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
  namespace: webapp
  labels:
    app: webapp
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: webapp
  template:
    metadata:
      labels:
        app: webapp
    spec:
      serviceAccountName: webapp-sa
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: webapp
      initContainers:
        - name: deps
          image: python:3.12-slim
          command:
            - pip
            - install
            - --no-cache-dir
            - --target
            - /deps
            - pymysql
            - boto3
          env:
            - name: HOME
              value: /tmp
            - name: PIP_CACHE_DIR
              value: /tmp/pip
            - name: PYTHONDONTWRITEBYTECODE
              value: "1"
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: deps
              mountPath: /deps
      containers:
        - name: app
          image: python:3.12-slim
          command:
            - python
            - /app/app.py
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: PYTHONPATH
              value: /deps
            - name: PYTHONUNBUFFERED
              value: "1"
            - name: PYTHONDONTWRITEBYTECODE
              value: "1"
            - name: HOME
              value: /tmp
            - name: DB_SECRET_ARN
              value: "${DB_SECRET_ARN}"
            - name: AWS_REGION
              value: "${REGION}"
            - name: AWS_DEFAULT_REGION
              value: "${REGION}"
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          # The startup probe gives the app up to 5 minutes to connect to the
          # database; liveness and readiness only begin after it succeeds.
          startupProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 30
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: deps
              mountPath: /deps
              readOnly: true
            - name: code
              mountPath: /app
              readOnly: true
      volumes:
        - name: tmp
          emptyDir: {}
        - name: deps
          emptyDir: {}
        - name: code
          configMap:
            name: webapp-code
---
apiVersion: v1
kind: Service
metadata:
  name: webapp
  namespace: webapp
spec:
  type: ClusterIP
  selector:
    app: webapp
  ports:
    - name: http
      port: 80
      targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: webapp
  namespace: webapp
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/subnets: "${PUBLIC_SUBNET_IDS}"
    alb.ingress.kubernetes.io/security-groups: "${ALB_SG_ID}"
    alb.ingress.kubernetes.io/manage-backend-security-group-rules: "false"
    alb.ingress.kubernetes.io/healthcheck-path: /healthz
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "15"
    alb.ingress.kubernetes.io/healthcheck-timeout-seconds: "5"
    alb.ingress.kubernetes.io/healthy-threshold-count: "2"
    alb.ingress.kubernetes.io/unhealthy-threshold-count: "3"
    alb.ingress.kubernetes.io/success-codes: "200"
    alb.ingress.kubernetes.io/listen-ports: '${LISTEN_PORTS}'
${INGRESS_TLS_ANNOTATIONS}
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: webapp
                port:
                  number: 80
