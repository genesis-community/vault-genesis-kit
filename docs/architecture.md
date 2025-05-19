# Vault Genesis Kit Architecture

This document provides a detailed overview of the Vault Genesis Kit architecture and components.

## Overview

The Vault Genesis Kit deploys a highly-available Vault cluster using Consul as the storage backend. The deployment consists of the following main components:

1. **Vault Servers** - The core Vault service that provides the secret management functionality
2. **Consul Cluster** - Provides the distributed storage backend for Vault
3. **Strongbox API** - A helper service that facilitates sealing/unsealing operations

## Deployment Architecture

```
┌────────────────────────────────────────────┐
│                                            │
│             Vault Cluster                  │
│                                            │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐│
│  │          │   │          │   │          ││
│  │  Vault   │   │  Vault   │   │  Vault   ││
│  │  Server  │   │  Server  │   │  Server  ││
│  │          │   │          │   │          ││
│  └────┬─────┘   └────┬─────┘   └────┬─────┘│
│       │              │              │      │
│       │              │              │      │
│  ┌────┴─────┐   ┌────┴─────┐   ┌────┴─────┐│
│  │          │   │          │   │          ││
│  │  Consul  │   │  Consul  │   │  Consul  ││
│  │  Server  │   │  Server  │   │  Server  ││
│  │          │   │          │   │          ││
│  └──────────┘   └──────────┘   └──────────┘│
│                                            │
│  ┌──────────┐                              │
│  │          │                              │
│  │Strongbox │                              │
│  │   API    │                              │
│  │          │                              │
│  └──────────┘                              │
│                                            │
└────────────────────────────────────────────┘
```

### Components

#### Vault Server

The Vault server provides the core functionality of the secret management system. Each Vault server in the cluster:

- Listens on HTTPS for client requests
- Processes authentication and authorization
- Handles encryption/decryption of secrets
- Manages access policies

In a standard deployment, we recommend a minimum of 3 Vault servers for high availability.

#### Consul Cluster

Consul serves as the storage backend for Vault and provides:

- Distributed key-value store for Vault data
- Consensus mechanism for consistency
- Service discovery
- Health checking

Each Vault server is co-located with a Consul server on the same VM.

#### Strongbox API

The Strongbox API provides a simplified interface for managing the seal/unseal process:

- Allows unsealing all Vault nodes with a single operation
- Provides status monitoring of the Vault cluster
- Facilitates operational management of the cluster

## High Availability and Fault Tolerance

The Vault Genesis Kit is designed to provide high availability and fault tolerance:

- The Consul backend requires a quorum (N/2+1) of nodes to remain operational
- For a 3-node cluster, it can tolerate the loss of 1 node
- For a 5-node cluster, it can tolerate the loss of 2 nodes

Recommended cluster sizes are 3, 5, or 7 nodes, depending on your fault tolerance requirements.

## Network Architecture

By default, the Vault servers are deployed on a dedicated network called `vault`, but this can be customized. The servers communicate with each other using internal IPs, and can be accessed by clients via their external IPs or load balancer.

Key network ports:
- **8200**: Vault API/UI
- **8201**: Vault cluster communication
- **8500**: Consul API
- **8301**: Consul LAN gossip
- **8302**: Consul WAN gossip

## Security Considerations

The Vault Genesis Kit implements several security best practices:

1. **TLS Encryption**: All communication is secured with TLS
2. **Auto-generated Certificates**: Certificates are generated and managed automatically
3. **Sealed by Default**: Vault starts in a sealed state and requires explicit unsealing
4. **Separation of Concerns**: Different teams can manage different secrets paths