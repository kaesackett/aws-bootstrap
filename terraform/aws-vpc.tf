provider "aws" {
  access_key = "${var.aws_access_key}"
  secret_key = "${var.aws_secret_key}"
  region = "${var.aws_region}"
}

resource "aws_vpc" "default" {
  cidr_block = "${var.vpc_cidr}"
  enable_dns_hostnames = true
  enable_dns_support = true
  tags {
    Name = "default vpc"
  }
}

resource "aws_internet_gateway" "gateway" {
  vpc_id = "${aws_vpc.default.id}"
}

# NAT instance

resource "aws_security_group" "nat" {
  name = "vpc_nat"
  description = "Allow traffic to pass from the private subnet to the internet"
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["${aws_subnet.private-subnet.cidr_block}"]
   }
   ingress {
     from_port = 443
     to_port = 443
     protocol = "tcp"
     cidr_blocks = ["${aws_subnet.private-subnet.cidr_block}"]
   }
   ingress {
     from_port = 22
     to_port = 22
     protocol = "tcp"
     cidr_blocks = ["0.0.0.0/0"]
   }
   ingress {
     from_port = -1
     to_port = -1
     protocol = "icmp"
     cidr_blocks = ["0.0.0.0/0"]
   }

   egress {
     from_port = 80
     to_port = 80
     protocol = "tcp"
     cidr_blocks = ["0.0.0.0/0"]
   }
   egress {
     from_port = 443
     to_port = 443
     protocol = "tcp"
     cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["${var.vpc_cidr}"]
  }
  egress {
    from_port = -1
    to_port = -1
    protocol = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  vpc_id = "${aws_vpc.default.id}"
  tags {
    Name = "nat SG"
  }
}

resource "aws_instance" "nat" {
  ami = "${var.aws_nat_ami}"
  availability_zone = "${var.availability_zone}"
  instance_type = "${var.instance_type}"
  key_name = "${aws_key_pair.auth.id}"
  security_groups = ["${aws_security_group.nat.id}"]
  subnet_id = "${aws_subnet.public-subnet.id}"
  associate_public_ip_address = true
  source_dest_check = false
  tags = {
    Name = "nat"
    subnet = "public-subnet"
    role = "nat"
  }
}

resource "aws_eip" "nat" {
  instance = "${aws_instance.nat.id}"
  vpc = true
}

# Public subnets

resource "aws_subnet" "public-subnet" {
  vpc_id = "${aws_vpc.default.id}"
  cidr_block = "10.0.0.0/24"
  availability_zone = "${var.availability_zone}"
  tags {
    Name = "Public subnet"
  }
}

# Routing table for public subnets

resource "aws_route_table" "public-route-table" {
  vpc_id = "${aws_vpc.default.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.gateway.id}"
  }
  tags {
      Name = "Public RT"
  }
}

resource "aws_route_table_association" "public-subnet" {
  subnet_id = "${aws_subnet.public-subnet.id}"
  route_table_id = "${aws_route_table.public-route-table.id}"
}

# Private subnets

resource "aws_subnet" "private-subnet" {
  vpc_id = "${aws_vpc.default.id}"
  cidr_block = "${var.private_subnet_cidr}"
  availability_zone = "${var.availability_zone}"
  tags {
    Name = "Private subnet"
  }
}

# Routing table for private subnets

resource "aws_route_table" "private-route-table" {
  vpc_id = "${aws_vpc.default.id}"
  route {
    cidr_block = "0.0.0.0/0"
    instance_id = "${aws_instance.nat.id}"
  }
  tags {
    Name = "Private RT"
  }
}

resource "aws_route_table_association" "private-subnet" {
  subnet_id = "${aws_subnet.private-subnet.id}"
  route_table_id = "${aws_route_table.private-route-table.id}"
}

# Key pair

resource "aws_key_pair" "auth" {
  key_name = "${var.aws_key_name}"
  public_key = "${file(var.public_key_path)}"
}

# Bastion

resource "aws_security_group" "bastion" {
  name      = "bastion"
  vpc_id      = "${aws_vpc.default.id}"
  description = "Bastion security group"
  tags {
    Name = "bastion SG"
  }

  ingress {
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["0.0.0.0/0"]
  }

  # NAT
  ingress {
    from_port = 0
    to_port = 65535
    protocol = "tcp"
    cidr_blocks = [
      "${aws_subnet.private-subnet.cidr_block}",
      "${aws_subnet.public-subnet.cidr_block}"
    ]
    self = false
  }

  egress {
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["${aws_subnet.private-subnet.cidr_block}", "${aws_subnet.public-subnet.cidr_block}"]
  }
}

resource "aws_instance" "bastion" {
  ami = "${var.aws_ubuntu_ami}"
  availability_zone = "${var.availability_zone}"
  instance_type = "${var.instance_type}"
  security_groups = ["${aws_security_group.bastion.id}"]
  subnet_id = "${aws_subnet.public-subnet.id}"
  connection {
    user = "ubuntu"
  }
  key_name = "${aws_key_pair.auth.id}"
  tags = {
    Name = "bastion"
    subnet = "public-subnet"
    role = "bastion"
  }
}

resource "aws_security_group" "allow_bastion" {
  name = "allow_bastion_ssh"
  description = "Allow access from bastion host"
  vpc_id = "${aws_vpc.default.id}"
  ingress {
    from_port = 0
    to_port = 65535
    protocol = "tcp"
    security_groups = [
      "${aws_security_group.bastion.id}",
      "${aws_security_group.nat.id}",
      "${aws_security_group.elb.id}",
      "${aws_security_group.app.id}" 
    ]
    self = false
  }
  tags = {
    Name = "allow bastion SG"
  }
}

resource "aws_eip" "bastion" {
  instance = "${aws_instance.bastion.id}"
  vpc = true
}

# ACL

#resource "aws_network_acl" "acl" {
#  vpc_id = "${aws_vpc.default.id}"
#  subnet_ids = [
#      "${aws_subnet.public-subnet.id}",
#      "${aws_subnet.private-subnet.id}"
#      ]
#  ingress {
#    protocol   = "-1"
#    rule_no    = 100
#    action     = "allow"
#    cidr_block = "0.0.0.0/0"
#    from_port  = 0
#    to_port    = 0
#  }
#
#  egress {
#    protocol   = "-1"
#    rule_no    = 100
#    action     = "allow"
#    cidr_block = "0.0.0.0/0"
#    from_port  = 0
#    to_port    = 0
#  }
#
#}
#
#resource "aws_network_acl_rule" "acl" {
#    network_acl_id = "${aws_network_acl.acl.id}"
#    rule_number = 200
#    egress = false
#    protocol = "tcp"
#    rule_action = "allow"
#    cidr_block = "0.0.0.0/0"
#    from_port = 22
#    to_port = 22
#}

# ELB

resource "aws_security_group" "elb" {
  name      = "app.elb"
  vpc_id = "${aws_vpc.default.id}"
  description = "Security group for App ELB"

  tags = {
    Name = "elb SG"
  }

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
      from_port = -1
      to_port = -1
      protocol = "icmp"
      cidr_blocks = ["0.0.0.0/0"]
  }

  egress { # App
      from_port = 8080
      to_port = 8080
      protocol = "tcp"
      cidr_blocks = ["${aws_subnet.private-subnet.cidr_block}"]
  }

}

resource "aws_elb" "blue" {
  name                  = "app-blue"
  connection_draining       = true
  connection_draining_timeout = 400

  subnets = ["${aws_subnet.public-subnet.id}"]
  security_groups = ["${aws_security_group.elb.id}"]

  tags = {
    Name = "elb blue"
    subnet = "public-subnet"
    role = "load balancer"
  }

  listener {
    lb_port         = 80
    lb_protocol       = "http"
    instance_port     = 8080
    instance_protocol = "http"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout           = 10
    interval          = 15
    target            = "HTTP:8080/"
  }

  instances = ["${aws_instance.app.id}"]
  cross_zone_load_balancing = true
  idle_timeout = 400
  connection_draining = true
  connection_draining_timeout = 400

}

resource "aws_elb" "green" {
  name                  = "app-green"
  connection_draining       = true
  connection_draining_timeout = 400

  subnets = ["${aws_subnet.public-subnet.id}"]
  security_groups = ["${aws_security_group.elb.id}"]

  tags = {
    Name = "elb green"
    subnet = "public-subnet"
    role = "load balancer"
  }

  listener {
    lb_port         = 80
    lb_protocol       = "http"
    instance_port     = 8080
    instance_protocol = "http"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout           = 10
   interval          = 15
    target            = "HTTP:8080/"
  }

  instances = ["${aws_instance.app.id}"]
  cross_zone_load_balancing = true
  idle_timeout = 400
  connection_draining = true
  connection_draining_timeout = 400

}

resource "aws_security_group" "app" {
  name      = "app"
  vpc_id = "${aws_vpc.default.id}"
  description = "Security group for App"

  tags = {
    Name = "app SG"
  }

  ingress {
    protocol    = "tcp"
    from_port   = 8080
    to_port     = 8080
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["${aws_subnet.public-subnet.cidr_block}"]
  }

  ingress {
      from_port = -1
      to_port = -1
      protocol = "icmp"
      cidr_blocks = ["${aws_vpc.default.cidr_block}"]
  }

  egress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

# Apps

resource "aws_instance" "app" {
  ami = "${var.aws_ubuntu_ami}"
  availability_zone = "${var.availability_zone}"
  instance_type = "${var.instance_type}"
  key_name = "${aws_key_pair.auth.id}"
  security_groups = ["${aws_security_group.app.id}"]
  subnet_id = "${aws_subnet.private-subnet.id}"
  source_dest_check = false
  connection {
    user = "ubuntu"
  }
  tags = {
    Name = "app"
    subnet = "public-subnet"
    role = "app"
  }
}

