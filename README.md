![GitHub Workflow Status](https://img.shields.io/github/workflow/status/RubiconDeFi/rubicon-protocol-v1/Truffle%20Tests)
![Discord](https://img.shields.io/discord/752590582274326680?link=https://discord.com/invite/E7pS24J&link=https://discord.com/invite/E7pS24J)

## Docs

For detailed documentation of the Rubicon protocol, please visit our [docs](https://docs.rubicon.finance/)

# Rubicon Protocol

Rubicon v1 is an order book protocol for Ethereum. It implements order books with native liquidity pools.

Rubicon v1 is built on Ethereum Layer 2 (L2) networks, and will launch across multiple L2s throughout the year. The protocol is currently live on [Optimism]([url](https://www.optimism.io/)). You can use it today on the [Rubicon App](https://app.rubicon.finance).

### Protocol Overview

Rubicon v1 smart contract architecture, with contracts in red and system roles in green:

![Rubicon v1_ RubiconMarket](https://user-images.githubusercontent.com/32072172/159312652-a8a82329-844c-4315-8b0c-dd6d85cf49ce.png)

At a high level, Rubicon v1 revolves around a core order book contract [RubiconMarket.sol](https://github.com/RubiconDeFi/rubicon-protocol-v1/blob/master/contracts/RubiconMarket.sol) that facilitates peer-to-peer trades of ERC-20 tokens.

[Rubicon Pools](https://github.com/RubiconDeFi/rubicon-protocol-v1/tree/master/contracts/rubiconPools) is a separate system of smart contracts that enables passive liquidity provisioning on the Rubicon order books.

## Security
Please report any findings to security@rubicon.finance.

## Start Rubicon Protocol Locally

```bash
$ git clone https://www.github.com/RubiconDeFi/rubicon-protocol-v1.git   
$ cd rubicon-protocol-v1 && npm i
$ (in a separate instance) npm run ganache
$ npm run test
```
