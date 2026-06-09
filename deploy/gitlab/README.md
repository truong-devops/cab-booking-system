# GitLab CI Pipeline Chuẩn Bị Deploy

File `gitlab-ci.yml` là pipeline chuẩn bị deploy cho luồng:

```text
commit -> verify -> secret scan -> SAST -> quality gate -> build image -> Trivy image scan -> update GitOps
```

## Vì sao cần file này?

Trong production, bạn không nên SSH vào VPS rồi `docker build` thủ công. CI/CD phải làm phần lặp lại:

- kiểm tra code và contract;
- quét secret bằng Gitleaks;
- quét SAST bằng Semgrep;
- quét dependency/filesystem bằng Trivy;
- gửi quality report lên SonarQube;
- build image bằng Kaniko;
- push image vào Harbor;
- cập nhật image tag trong GitOps repo để Argo CD tự sync.

## Biến CI cần tạo trong GitLab

Tạo ở `Settings -> CI/CD -> Variables`:

| Variable | Ý nghĩa |
| --- | --- |
| `HARBOR_REGISTRY` | Domain Harbor, điền theo domain thật của bạn. |
| `HARBOR_PROJECT` | Project Harbor, ví dụ project `cab`. |
| `HARBOR_USERNAME` | Robot account có quyền push image. |
| `HARBOR_PASSWORD` | Token/password của robot account. |
| `SONAR_HOST_URL` | URL SonarQube theo domain thật của bạn. |
| `SONAR_TOKEN` | Token để gửi report lên SonarQube. |
| `GITOPS_HOST` | Host GitOps repo theo domain thật của bạn. |
| `GITOPS_REPO_SSH_URL` | SSH URL của GitOps repo. |
| `GITOPS_DEPLOY_KEY` | Private key chỉ có quyền push GitOps repo. |

## Cách dùng

1. Copy file này thành `.gitlab-ci.yml` khi GitLab Runner và Harbor đã sẵn sàng.
2. Thay `harbor.your-domain.com`, `cab`, GitOps path theo hệ thống thật.
3. Production chỉ nên update bằng tag Git, job production đang để `manual`.
