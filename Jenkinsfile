pipeline {
    agent any

    environment {
        IMAGE_NAME = 'rayyan43/devops-lab-app'
        IMAGE_TAG  = "${BUILD_NUMBER}"
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Install dependencies') {
            steps {
                dir('app') {
                    sh '''
                        python3 -m venv venv
                        . venv/bin/activate
                        pip install -r requirements.txt
                    '''
                }
            }
        }

        stage('Lint') {
            steps {
                dir('app') {
                    sh '''
                        . venv/bin/activate
                        flake8 .
                    '''
                }
            }
        }

        stage('Test') {
            steps {
                dir('app') {
                    sh '''
                        . venv/bin/activate
                        python -m pytest tests/ -v
                    '''
                }
            }
        }

        stage('Build image') {
            steps {
                sh "docker build -t ${IMAGE_NAME}:${IMAGE_TAG} -t ${IMAGE_NAME}:latest app/"
            }
        }

        stage('Push image') {
            steps {
                withCredentials([usernamePassword(
                    credentialsId: 'dockerhub',
                    usernameVariable: 'DOCKER_USER',
                    passwordVariable: 'DOCKER_PASS'
                )]) {
                    sh '''
                        echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
                        docker push ''' + "${IMAGE_NAME}:${IMAGE_TAG}" + '''
                        docker push ''' + "${IMAGE_NAME}:latest" + '''
                        docker logout
                    '''
                }
            }
        }

        stage('Deploy') {
            steps {
                sh """
                    docker rm -f devops-lab-app || true
                    docker run -d --name devops-lab-app \
                        --network tool-stack_default \
                        -p 5000:5000 \
                        ${IMAGE_NAME}:${IMAGE_TAG}
                """
            }
        }

        stage('Smoke test') {
            steps {
                sh '''
                    sleep 5
                    curl -f http://devops-lab-app:5000/health
                '''
            }
        }
    }

    post {
        success {
            echo "Build ${BUILD_NUMBER} deployed successfully"
        }
        failure {
            echo "Build ${BUILD_NUMBER} failed"
        }
        always {
            sh 'docker image prune -f || true'
        }
    }
}