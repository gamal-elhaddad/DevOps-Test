terraform {
  required_version = ">=0.12"
  backend "s3" {
    bucket = "terraform-main-state-bucket"
    key    = "terraform-state/state.tfstate"
    region = "me-central-1"
  }
}

provider "aws" {
  region = "me-central-1"
}

resource "aws_vpc" "eks_vpc" {
  cidr_block = "10.1.0.0/16"
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.eks_vpc.id
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = "10.1.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.eks_vpc.id
}

resource "aws_route" "public_route" {
  route_table_id         = aws_route_table.public_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_association" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_eip" "nat_eip" {
  vpc = true
}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id
}

resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.eks_vpc.id
  cidr_block        = "10.1.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.eks_vpc.id
}

resource "aws_route" "private_route" {
  route_table_id         = aws_route_table.private_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat_gw.id
}

resource "aws_route_table_association" "private_association" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_route_table.id
}

data "aws_availability_zones" "available" {}

data "aws_iam_role" "eks_role" {
  name = "EKSRole"
}

resource "aws_eks_cluster" "test" {
  name     = "test"
  role_arn = data.aws_iam_role.eks_role.arn

  vpc_config {
    subnet_ids = [aws_subnet.public_subnet.id, aws_subnet.private_subnet.id]
  }
}

resource "aws_eks_node_group" "test" {
  cluster_name    = aws_eks_cluster.test.name
  node_group_name = "test-node-group"
  node_role_arn   = "arn:aws:iam::084395075593:role/EKS-Worker_node-Role"
  subnet_ids      = [aws_subnet.public_subnet.id, aws_subnet.private_subnet.id]
  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }
}

resource "aws_security_group" "eks_node_sg" {
  name_prefix = "eks_node_sg"
  description = "Security group for EKS nodes"
  vpc_id      = aws_vpc.eks_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.eks_vpc.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "eks_node_cluster_ingress" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.eks_cluster_sg.id
  security_group_id        = aws_security_group.eks_node_sg.id
}

resource "aws_security_group" "eks_cluster_sg" {
  name_prefix = "eks_cluster_sg"
  description = "Security group for EKS cluster"
  vpc_id      = aws_vpc.eks_vpc.id