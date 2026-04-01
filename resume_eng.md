---
layout: default
title: Resume (English)
nav_order: 2
---

# Jack Ho

<img src="avatar.jpeg" alt="Jack Ho" width="150" style="border-radius: 50%;">

u0052041@gmail.com

Backend engineer with 7 years of Python experience. Worked on high-traffic systems, focusing on system design and performance improvement. Led core feature development at a video platform with 500K daily active users. Also have hands-on experience in database tuning, cache tuning, payment integration, and third-party service integration. Have production CI/CD experience, and also built AWS/Terraform infrastructure and Kubernetes deployments through side projects. Now looking to move into DevOps roles.

---

## Work Experience

### Heng Yuan Technology — Senior Backend Engineer (2023/02 - 2026/01)

Worked on a video streaming platform with 500K DAU. Built core features for both the client app and admin system, and joined technical reviews to help make sure features could be delivered smoothly.

- Worked with DBAs on table partitioning and API query optimization for high-traffic workloads, removed slow queries, and reduced RDS cost by two instance sizes
- Split large ElastiCache keys into smaller shards and adjusted data structures, reducing ElastiCache cost by one instance size
- Added in-process cache with active invalidation for high-read, low-change data, reducing Redis queries
- Integrated a third-party live streaming service from technical review and API integration to production support, including virtual currency top-up and spending flows, while keeping transaction data correct
- Integrated a third-party messaging service for both user messaging and the admin customer service system, including customer service assignment logic
- Reworked the video processing flow by encrypting FFmpeg segments and uploading them directly to AWS S3, replacing a third-party cloud service and reducing upload failures

### UrMart — Backend Engineer (2021/04 - 2023/02)

Worked on the new e-commerce website from development to post-launch improvements, including payment, logistics, and SMS integrations.

- Improved core APIs such as product listing, cart, and checkout, keeping response time stable at 200-300ms
- Integrated PxPay and TapPay, and reworked the payment flow to use one shared logic across different payment methods
- Handled load testing for major sales events such as 11.11, estimated server capacity for peak traffic, and kept the system stable with 2,000 concurrent users
- Wrote complex SQL in Metabase for data analysis and provided key business metrics for other teams
- Took part in CI/CD setup and improved Elastic Beanstalk deployment to shorten release time

### Wang Zu Game Technology — Backend Engineer (2016/10 - 2021/03)

Started as IT staff and moved into backend development through self-study. Built an internal management system from scratch. Wrote integration tests to protect core features, fixed N+1 query problems to improve performance, and used Python and Selenium to automate repeated manual work.

## DevOps Practice

Built AWS infrastructure and CI/CD flows from scratch through side projects and gained hands-on DevOps experience.

- Used Terraform to manage AWS resources such as VPC, Subnet, ALB, ACM, and ECS, and practiced Infrastructure as Code
- Connected ACM wildcard certificates with ALB to set up HTTPS traffic
- Built Jenkins Pipelines with ECS Agents to support dynamic build agents in CI/CD workflows
- Deployed applications to EKS and wrote Kubernetes manifests for Ingress, Service, and Deployment

## Skills

**Backend:** Python, Celery, Redis, RabbitMQ, PostgreSQL/MySQL, MongoDB, Nginx

**DevOps:** GitHub Actions, Docker, AWS, GCP, Terraform, Jenkins

**Others:** Git, JavaScript/jQuery, Selenium, FFmpeg, Scrum
