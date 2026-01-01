# ☸️ Kubernetes Helm Charts

A curated collection of Helm charts for deploying security tools, AI infrastructure, and automation services on Kubernetes (K3S).

This repository contains custom-configured charts designed for ease of use, stability, and security hardening. 
Whether you are running a home lab or a security infrastructure, these charts help you deploy complex stacks with a single command.

## 🚀 Chart Collection

### 🛡️ Security & Auditing
| Chart | Description |
| :--- | :--- |
| **[BloodHound](/bloodhound/README.md)** | Active Directory security auditing and attack path management tool. |
| **[Falco](/falco/README.md)** | Cloud-native runtime security project for detecting threats in Kubernetes. |

### 🤖 AI & LLMs
| Chart | Description |
| :--- | :--- |
| **[Ollama](/ollama/README.md)** | Get up and running with large language models locally. |
| **[OpenUI](/openui/README.md)** | A lightweight, flexible UI for interacting with LLMs (great companion for Ollama). |

### ⚡ Automation & Utilities
| Chart | Description |
| :--- | :--- |
| **[N8N](/n8n-hosting/README.md)** | Workflow automation tool. Create complex automations with a fair-code workflow. |
| **[ActualBudget](/actualbudget/README.md)** | A super fast, privacy-focused local-first personal finance system. |

---

## 🛠️ Usage

### Prerequisites
- Kubernetes 1.24+
- Helm 3.0+

### Installing a Chart
To install a chart directly from this repository (assuming local clone):

```bash
# Example: Installing Ollama
helm upgrade --install ollama ./ollama -n ollama --create-namespace