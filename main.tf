terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.27"
    }
  }

  required_version = ">= 0.12.31"
}

provider "aws" {
  profile = "default"
  region  = "us-east-2"
}

data "aws_availability_zones" "available" {
  state = "available"
}

variable "cidr"{
  default = "10.0.0.0/16"
}

variable "public-cidr" {
  default = "10.0.0.0/24"
}

variable "private-cidr" {
  default = "10.0.1.0/24"
}

variable "ecs-task-role" {
  default = "arn:aws:iam::298467709983:role/ecsTask"
}

variable "ecs-task-execution-role" {
  default = "arn:aws:iam::298467709983:role/ecsTaskExecutionRole"
}

variable "container_port" {
  default = 8000
}

variable "health_check_path" {
  default = "/services"
}

resource "aws_vpc" "main" {
  cidr_block = var.cidr
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  vpc_id = aws_vpc.main.id
  cidr_block = var.public-cidr
  availability_zone = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  vpc_id = aws_vpc.main.id
  cidr_block = var.private-cidr
  availability_zone = data.aws_availability_zones.available.names[1]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "public" {
  route_table_id = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  subnet_id = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  vpc = true
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id = aws_subnet.public.id
  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "private" {
  route_table_id = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "private" {
  subnet_id = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "alb" {
  name = "real-estate-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    protocol = "tcp"
    from_port = 80
    to_port = 9000
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    protocol = "-1"
    from_port = 0
    to_port = 0
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_security_group" "ecs_tasks" {
  name = "real-estate-task-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    protocol = "tcp"
    from_port = var.container_port
    to_port = var.container_port
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    protocol         = "-1"
    from_port        = 0
    to_port          = 0
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_ecr_repository" "main" {
  name = "real-estate-images"
  image_tag_mutability = "MUTABLE"
}

resource "aws_ecr_lifecycle_policy" "main" {
  repository = aws_ecr_repository.main.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 10 images"
      action       = {
        type = "expire"
      }
      selection     = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
    }]
  })
}

resource "aws_ecs_cluster" "main" {
  name = "real-estate-cluster"
}

resource "aws_ecs_task_definition" "main" {
  network_mode = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu = 256
  memory = 512
  execution_role_arn = var.ecs-task-role
  task_role_arn = var.ecs-task-role
  family = "real-estate"
  container_definitions = jsonencode([{
    name = "real-estate-container"
    image = "298467709983.dkr.ecr.us-east-2.amazonaws.com/real-estate-images:latest"
    essential = true
    portMappings = [
      {
        protocol = "tcp"
        containerPort = var.container_port
        hostPort = var.container_port
      }]
  }])
}

resource "aws_lb" "main" {
  name = "real-estate-alb"
  internal = false
  load_balancer_type = "application"
  security_groups = [aws_security_group.ecs_tasks.id]
  subnets = [aws_subnet.public.id, aws_subnet.private.id]
  enable_deletion_protection = false
}

resource "aws_ecs_service" "main" {
  name = "real-estate-service"
  cluster = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.main.id
  desired_count = 2
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent = 200
  launch_type = "FARGATE"
  scheduling_strategy = "REPLICA"

  network_configuration {
    security_groups = [aws_security_group.ecs_tasks.id]
    subnets = [aws_subnet.private.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.main.arn
    container_name = "real-estate-container"
    container_port = var.container_port
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}

resource "aws_alb_target_group" "main" {
  name = "real-estate-tg"
  port = 80
  protocol = "HTTP"
  vpc_id = aws_vpc.main.id
  target_type = "ip"

  health_check {
    healthy_threshold = "3"
    interval = "30"
    protocol = "HTTP"
    matcher = "200"
    timeout = "3"
    path = var.health_check_path
    unhealthy_threshold = "2"
  }

  depends_on = [aws_lb.main]
}

resource "aws_alb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "forward"
    target_group_arn = aws_alb_target_group.main.arn

    redirect {
      port        = 8000
      protocol    = "HTTP"
      status_code = "HTTP_301"
    }
  }
}

/*resource "aws_alb_listener" "https" {
  load_balancer_arn = aws_lb.main.id
  port              = 443
  protocol          = "HTTPS"

  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = var.alb_tls_cert_arn

  default_action {
    target_group_arn = aws_alb_target_group.main.id
    type             = "forward"
  }
}*/

resource "aws_appautoscaling_target" "ecs_target" {
  max_capacity       = 4
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_policy_memory" {
  name               = "memory-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }

    target_value       = 80
  }
}

resource "aws_appautoscaling_policy" "ecs_policy_cpu" {
  name               = "cpu-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value       = 60
  }
}

