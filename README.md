# InvestInGas - ETH-Native Gas Futures

Uniswap v4 hook for gas futures trading. Users deposit USDC, receive NFT positions representing locked gas, and redeem as native ETH/MATIC on target chains.

## Architecture

```
User deposits USDC → Hook swaps to WETH → NFT minted → User redeems → LiFi bridges ETH
```

## Contracts

- **InvestInGasHook.sol**: Uniswap v4 hook with ERC721 positions
- **LiFiBridger.sol**: Cross-chain gas delivery via LiFi
- **ILiFiBridger.sol**: Bridger interface

## Supported Chains

| Chain | Type |
|-------|------|
| Sepolia | Same-chain (direct transfer) |
| Arbitrum Sepolia | Cross-chain bridge |
| Base Sepolia | Cross-chain bridge |
| Polygon Amoy | Cross-chain bridge (ETH→MATIC) |

## Setup

```bash
# Install dependencies
forge install

# Build
forge build

# Test
forge test -vvv
```

## Deployment

```bash
# Copy env template
cp .env.example .env

# Edit .env with your private key
# Then deploy to Sepolia
forge script script/DeployInvestInGas.s.sol --rpc-url $SEPOLIA_RPC --broadcast
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| PRIVATE_KEY | Deployer wallet private key |
| RELAYER_ADDRESS | (Optional) Relayer address, defaults to deployer |
| SEPOLIA_RPC | Sepolia RPC URL |

## License

MIT
