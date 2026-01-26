# Bittensor Treasury Controller & Vault

A specialized governance system designed for the Bittensor network. This project provides a robust framework for managing treasury funds, automating subnet operations, and enabling stake-based decentralized decision-making.

## 🏗 Architecture Overview

The system consists of two primary smart contracts:

### 1. TreasuryController (`src/controller/`)
A custom **Governor** implementation based on OpenZeppelin, optimized for Bittensor:
- **Stake-Based Voting**: Instead of standard ERC20 tokens, it leverages real-time stake and delegation data from the Bittensor network via the `IBittensorVotes` interface.
- **Subnet-Scoped**: Governance is targeted at a specific `netuid`, ensuring that only stakeholders relevant to that subnet have voting power.
- **Adjustable Quorum**: A configurable quorum numerator allows for flexible governance thresholds.

### 2. TreasuryVault (`src/vault/`)
A sophisticated **TimelockController** that acts as the "braim" and "safe" of the system:
- **Foundry-Compatible Timelock**: Inherits proven security from OpenZeppelin's `TimelockController`.
- **Neuron Registration**: Directly integrates with the `NEURON_PRECOMPILE` (0x804) on the Bittensor EVM layer. This allows the vault to autonomously register neurons/hotkeys on subnets using treasury funds.
- **Automated Refunds**: Handles surplus TAO during registration processes, ensuring funds are returned to the caller.

---

## 💎 Key Differences from "Standard" Vaults

While built on top of industry-standard OpenZeppelin contracts, this implementation introduces critical enhancements for the Bittensor ecosystem:

| Feature | Standard OpenZeppelin Vault | Bittensor Treasury |
|---------|-----------------------------|-------------------|
| **Voting Power** | ERC20 / NFT Snapshot | **Live Bittensor Stake/Delegation** |
| **Asset Focus** | Standard EVM Tokens | **Native TAO & Subnet Alpha** |
| **Network Ops** | Pure Token Storage | **Direct Subnet Registration (Precompiles)** |
| **Governance** | General Purpose | **Subnet-Specific (NetUID Scoped)** |

---

## 🛠 Documentation & Tooling

To simplify interaction with these complex contracts, a dedicated Python toolset is provided.

- 📖 **[Python Tooling & Automation Guide](tools/README.md)**: Detailed documentation for proposing, voting, and managing the vault using our automated scripts.

---

## 🚀 Development & Usage

### Prerequisites
- [Foundry](https://book.getfoundry.sh/)
- Python 3.9+

### Build & Test
```shell
# Compile contracts
forge build

# Run unit tests
forge test
```

### Deployment
Use the Foundry scripts located in `script/` (e.g., `forge script script/Deployment.s.sol`).

---

## 🛡 Security
This project uses OpenZeppelin's battle-tested governance and timelock patterns. However, users should always verify contract addresses and parameters before committing significant capital.
