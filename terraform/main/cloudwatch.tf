resource "aws_cloudwatch_metric_alarm" "app_cpu" {
  alarm_name          = "devops-lab-app-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 70

  dimensions = {
    InstanceId = aws_instance.app.id
  }

  alarm_description = "App server CPU above 70 percent"
}

resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/devops-lab/app-server"
  retention_in_days = 7
}