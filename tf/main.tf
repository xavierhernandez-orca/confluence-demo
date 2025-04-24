# (Snippet) Terraform EKS cluster creation
resource "aws_eks_cluster" "demo_cluster" {
  name     = "orca-eks-demo"
  role_arn = aws_iam_role.eks_master.arn

  vpc_config {
    subnet_ids = [aws_subnet.public1.id, aws_subnet.public2.id]
  }

  # Enable control plane logging for API & audit
  enabled_cluster_log_types = ["api", "audit", "authenticator"]
}

resource "aws_iam_role" "eks_node_role" {
  name = "orcaEKSNodeRole"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume.json
}
resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_role.name
}
resource "aws_iam_role_policy_attachment" "node_CNI" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_role.name
}
resource "aws_iam_role_policy_attachment" "node_ECR_readonly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_role.name
}
# *** Attach extra permissions for demo (S3 read access) ***
resource "aws_iam_policy" "extra_node_policy" {
  name   = "OrcaDemoNodeExtraPolicy"
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": ["s3:ListBucket", "s3:GetObject"],
        "Resource": [
          "arn:aws:s3:::my-orca-demo-bucket",
          "arn:aws:s3:::my-orca-demo-bucket/*"
        ]
      }
    ]
  })
}
resource "aws_iam_role_policy_attachment" "node_extra_s3" {
  policy_arn = aws_iam_policy.extra_node_policy.arn
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_eks_node_group" "demo_nodes" {
  cluster_name    = aws_eks_cluster.demo_cluster.name
  node_group_name = "demo-nodes"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnets         = [aws_subnet.public1.id, aws_subnet.public2.id]
  scaling_config {
    desired_size = 2
    max_size     = 2
    min_size     = 2
  }
  # Disable IMDSv2 requirement for demo (make metadata easily accessible)
  launch_template {
    id      = aws_launch_template.node_launch.id
    version = "$Latest"
  }
}
# Configure the launch template to allow IMDSv1 and hop limit 2
resource "aws_launch_template" "node_launch" {
  name_prefix   = "orca-eks-demo-node"
  image_id      = data.aws_ami.eks_worker.id
  instance_type = "t3.medium"
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "optional"   # Do not require IMDSv2 token
    http_put_response_hop_limit = 2   # Allows containers to query IMDS
  }
}
