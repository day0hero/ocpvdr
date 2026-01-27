# Multicloud Gitops

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

[Live build status](https://validatedpatterns.io/ci/?pattern=mcgitops)

## Start Here

If you've followed a link to this repository, but are not really sure what it contains
or how to use it, head over to [Multicloud GitOps](https://validatedpatterns.io/patterns/multicloud-gitops/)
for additional context and installation instructions

## Rationale

The goal for this pattern is to:

* Use a GitOps approach to manage hybrid and multi-cloud deployments across both public and private clouds.
* Enable cross-cluster governance and application lifecycle management.
* Securely manage secrets across the deployment.


## PreRequisites

- Create fsx policy (tested with fullfsx permissions)
- Create s3 policy 
- Create s3 bucket

|----|---|
| Permission           | Purpose                            | 
|----------------------|------------------------------------|
| s3:GetObject         | Read backup data                   | 
| s3:PutObject         | Write backups/snapshots            | 
| s3:DeleteObject      | Delete expired backups (retention) | 
| s3:ListBucket        | List backup contents               | 
| s3:GetBucketLocation | Determine bucket region            | 
