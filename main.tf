terraform {
  required_version = ">= 1.13"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "ip_block" {
  type      = string
  sensitive = true
}

variable "public_key" {
  type      = string
  sensitive = true
}

variable "access_key" {
  type      = string
  sensitive = true
}

variable "secret_key" {
  type      = string
  sensitive = true
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

provider "aws" {
  region     = "us-east-1"
  access_key = var.access_key
  secret_key = var.secret_key
}

resource "aws_vpc" "main" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"

  tags = {
    Name = "teczi-vpc"
  }
}

resource "aws_subnet" "public" {
  count                   = 1
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = var.availability_zones[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "teczi-public-subnet"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 2}.0/24"
  availability_zone = var.availability_zones[count.index + 1]

  tags = {
    Name = "teczi-private-subnet-${count.index + 1}"
  }
}

resource "aws_internet_gateway" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "teczi-gateway"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.public.id
  }

  tags = {
    Name = "teczi-public-route-table"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "main" {
  domain = "vpc"
}

resource "aws_nat_gateway" "private" {
  allocation_id = aws_eip.main.id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.public]

  tags = {
    Name = "teczi-nat"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.private.id
  }

  tags = {
    Name = "teczi-private-route-table"
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "frontend" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ip_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "teczi-frontend-sg"
  }
}

resource "aws_security_group" "backend" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend.id]
  }

  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "teczi-backend-sg"
  }
}

resource "aws_security_group" "rds" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.backend.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "teczi-rds-sg"
  }
}

resource "aws_key_pair" "default" {
  key_name   = "deployer"
  public_key = var.public_key
}

resource "aws_instance" "frontend" {
  ami                         = "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.frontend.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.default.key_name
  user_data = templatefile("${path.module}/config/frontend", {
    backend_host = aws_instance.backend.public_ip
  })

  tags = {
    Name = "teczi-frontend-instance"
  }
}

resource "aws_instance" "backend" {
  ami                         = "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.private[0].id
  vpc_security_group_ids      = [aws_security_group.backend.id]
  associate_public_ip_address = false
  key_name                    = aws_key_pair.default.key_name
  user_data = templatefile("${path.module}/config/backend", {
    db_host     = aws_db_instance.database.address
    db_port     = aws_db_instance.database.port
    db_name     = aws_db_instance.database.db_name
    db_user     = aws_db_instance.database.username
    db_password = aws_db_instance.database.password
  })

  tags = {
    Name = "teczi-backend-instance"
  }
}

resource "aws_db_subnet_group" "private" {
  name       = "private-subnets"
  subnet_ids = [for subnet in aws_subnet.private : subnet.id]

  tags = {
    Name = "teczi-private-subnet-group"
  }
}

resource "aws_db_instance" "database" {
  engine                 = "postgres"
  allocated_storage      = 20
  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.private.id
  db_name                = "teczi"
  identifier             = "teczi-rds"
  skip_final_snapshot    = true
  instance_class         = "db.t4g.micro"
  username               = "postgres"
  password               = "postgres"
  multi_az               = false

  tags = {
    Name = "teczi-db-instance"
  }
}
