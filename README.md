![GitHub Workflow Status](https://img.shields.io/github/workflow/status/RubiconDeFi/rubicon-protocol-v1/Truffle%20Tests)
![Discord](https://img.shields.io/discord/752590582274326680?link=https://discord.com/invite/E7pS24J&link=https://discord.com/invite/E7pS24J)

## Docs

For detailed documentation of the Rubicon protocol please visit our [docs](https://docs.rubicon.finance/)

# Rubicon Protocol

Rubicon is an open order book protocol for Ethereum. The protocol is Layer 2-native and will launch across multiple L2 networks such as [Optimism](https://optimism.io/), [Arbitrum](https://arbitrum.io/), [zkSync](https://zksync.io/), and [Polygon](https://polygon.technology/).

The Rubicon protocol is currently live on the Optimistic Ethereum network. You can use it today on the [Rubicon App](https://app.rubicon.finance).

### Protocol Overview

A number of key smart contracts house the primary operations of the Rubicon protocol. Please see below for an overview of our current smart contract infrastructure.

![Rubicon v1_ RubiconMarket](https://user-images.githubusercontent.com/32072172/159312652-a8a82329-844c-4315-8b0c-dd6d85cf49ce.png)

At a high level, Rubicon revolves around a core smart contract [RubiconMarket.sol](https://github.com/RubiconDeFi/rubicon-protocol-v1/blob/master/contracts/RubiconMarket.sol) that facilitates peer-to-peer trades of ERC-20 tokens using an open order book.

[Rubicon Pools](https://docs.rubicon.finance/contracts/rubicon-pools) is a separate system of smart contracts that enables passive liquidity provisioning on the Rubicon order books.

## Start Rubicon Protocol Locally

```bash
$ git clone https://www.github.com/RubiconDeFi/rubicon-protocol-v1.git   
$ cd rubicon-protocol-v1 && npm i
$ (in a separate instance) npm run ganache
$ npm run test
```
