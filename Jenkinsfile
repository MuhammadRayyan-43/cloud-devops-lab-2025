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

        stage('Build image') {
            steps {
                sh "docker build -t ${IMAGE_NAME}:${IMAGE_TAG} -t ${IMAGE_NAME}:latest app/"
            }
        }

        stage('Lint') {
            steps {
                sh "docker run --rm ${IMAGE_NAME}:${IMAGE_TAG} flake8 ."
            }
        }

        stage('Test') {
            steps {
                sh "docker run --rm ${IMAGE_NAME}:${IMAGE_TAG} python -m pytest tests/ -v"
            }
        }

        stage('SonarQube analysis') {
            steps {
                withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
                    sh """
                        docker run --rm \
                            --network tool-stack_default \
                            -v \$(pwd)/app:/usr/src \
                            sonarsource/sonar-scanner-cli \
                            -Dsonar.projectKey=devops-lab \
                            -Dsonar.sources=. \
                            -Dsonar.host.url=http://sonarqube:9000 \
                            -Dsonar.token=\$SONAR_TOKEN
                    """
                }
            }
        }        

        stage('Push image') {
            steps {
                withCredentials([usernamePassword(
                    credentialsId: 'dockerhub',
                    usernameVariable: 'DOCKER_USER',
                    passwordVariable: 'DOCKER_PASS'
                )]) {
                    sh """
                        echo \$DOCKER_PASS | docker login -u \$DOCKER_USER --password-stdin
                        docker push ${IMAGE_NAME}:${IMAGE_TAG}
                        docker push ${IMAGE_NAME}:latest
                        docker logout
                    """
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