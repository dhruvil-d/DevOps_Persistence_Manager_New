// =============================================================================
// Jenkinsfile – PV Manager Pipeline (Declarative Pipeline)
// =============================================================================
// Pipeline: Pre-deploy backup → Deploy → Verify → Rollback on failure
// Compatible with Jenkins 2.x with Blue Ocean or classic UI.
// =============================================================================

pipeline {
    agent any

    // ── Global environment variables ────────────────────────────────
    environment {
        PV_NAMESPACE      = 'pv-manager'
        PV_BACKUP_DIR     = "${WORKSPACE}/backups"
        KUBECTL_TIMEOUT   = '30s'
        KUBECONFIG        = credentials('kubeconfig')   // Jenkins Credentials binding
        PV_MANAGER        = "${WORKSPACE}/scripts/pv_manager.sh"
    }

    // ── Build options ────────────────────────────────────────────────
    options {
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()       // Prevent parallel pipeline conflicts
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timestamps()
        ansiColor('xterm')
    }

    // ── Trigger: on SCM change ───────────────────────────────────────
    triggers {
        pollSCM('H/5 * * * *')
    }

    stages {
        // ── Stage 1: Setup ─────────────────────────────────────────
        stage('Setup / Checkout') {
            steps {
                echo '═══════════════════════════════════════════════'
                echo ' PV Manager Pipeline – Setup & Checkout'
                echo '═══════════════════════════════════════════════'
                checkout scm
                sh '''
                    chmod +x "${PV_MANAGER}"
                    mkdir -p "${PV_BACKUP_DIR}"
                    kubectl version --client
                    kubectl cluster-info
                '''
            }
        }

        // ── Stage 2: Pre-Deployment Backup ─────────────────────────
        stage('Pre-Deploy Backup') {
            steps {
                echo '═══════════════════════════════════════════════'
                echo ' Stage: Pre-Deployment Backup'
                echo '═══════════════════════════════════════════════'
                script {
                    sh '"${PV_MANAGER}" status'

                    sh '"${PV_MANAGER}" backup'

                    // Capture backup filename for use in rollback stage
                    env.BACKUP_FILE = sh(
                        script: 'ls -t "${PV_BACKUP_DIR}"/backup_*.tar.gz 2>/dev/null | head -1',
                        returnStdout: true
                    ).trim()

                    echo "Pre-deploy backup created: ${env.BACKUP_FILE}"

                    if (!env.BACKUP_FILE) {
                        error('Backup file not found after backup command – aborting.')
                    }
                }
            }
            post {
                success {
                    archiveArtifacts artifacts: 'backups/backup_*.tar.gz',
                                     allowEmptyArchive: false,
                                     fingerprint: true
                }
            }
        }

        // ── Stage 2.5: Build Docker Image ──────────────────────────
        stage('Build Image') {
            steps {
                echo '═══════════════════════════════════════════════'
                echo ' Stage: Build Docker Image'
                echo '═══════════════════════════════════════════════'
                sh '''
                    # Optional: evaluate Minikube docker-env if running locally against Minikube
                    # eval $(minikube docker-env)
                    docker build -t pv-demo-app:latest ./app
                '''
            }
        }

        // ── Stage 3: Deploy Kubernetes Manifests ───────────────────
        stage('Deploy') {
            steps {
                echo '═══════════════════════════════════════════════'
                echo ' Stage: Deploying Kubernetes manifests'
                echo '═══════════════════════════════════════════════'
                sh '''
                    kubectl apply -f k8s/namespace.yaml
                    kubectl apply -f k8s/rbac.yaml
                    kubectl apply -f k8s/pv.yaml
                    kubectl apply -f k8s/pvc.yaml
                    kubectl apply -f k8s/deployment.yaml
                '''
                sh '''
                    kubectl rollout status deployment/pv-demo-app \
                        -n "${PV_NAMESPACE}" \
                        --timeout=120s
                '''
            }
        }

        // ── Stage 4: Post-Deploy Verification ──────────────────────
        stage('Post-Deploy Status') {
            steps {
                echo '═══════════════════════════════════════════════'
                echo ' Stage: Post-Deploy Status Check'
                echo '═══════════════════════════════════════════════'
                sh '"${PV_MANAGER}" status'
                sh '"${PV_MANAGER}" list'
            }
        }

        // ── Stage 5: Storage Monitoring ────────────────────────────
        stage('Monitor') {
            steps {
                echo '═══════════════════════════════════════════════'
                echo ' Stage: Storage & Resource Monitoring'
                echo '═══════════════════════════════════════════════'
                sh '"${PV_MANAGER}" monitor'
            }
        }

        // ── Stage 6: Enable Scheduled Backups ──────────────────────
        stage('Enable CronJob') {
            steps {
                echo '═══════════════════════════════════════════════'
                echo ' Stage: Enable Scheduled Backup CronJob'
                echo '═══════════════════════════════════════════════'
                sh '"${PV_MANAGER}" schedule on'
            }
        }
    }

    // ── Post-pipeline actions ────────────────────────────────────────
    post {
        failure {
            echo '══════════════════════════════════════════════════'
            echo ' PIPELINE FAILED – Initiating Emergency Restore'
            echo '══════════════════════════════════════════════════'
            script {
                if (env.BACKUP_FILE) {
                    sh '"${PV_MANAGER}" restore "${BACKUP_FILE}"'
                    sh '"${PV_MANAGER}" status'
                } else {
                    echo 'No backup file available for restore. Manual intervention required.'
                }
            }
        }
        always {
            echo 'Pipeline complete.'
            // Archive any backup files created during this run
            archiveArtifacts artifacts: 'backups/*.tar.gz',
                             allowEmptyArchive: true
        }
        success {
            echo 'Pipeline succeeded. PV data is safe.'
        }
    }
}
