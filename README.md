# Vault - Production-Grade ERC-4626 Vault

Fully compliant ERC-4626 vault with **unlimited deposits**, **vault-favorable rounding**, and **battle-tested security**.

## 🚀 Features

- ✅ **Full ERC-4626 compliance** (deposit/mint/withdraw/redeem)
- ✅ **Full ERC-20 compliance** (transfer/approve/transferFrom)
- ✅ **Unlimited deposits** (`type(uint256).max`)
- ✅ **Vault-favorable math** (rounds down on deposit, up on withdraw)
- ✅ **Reentrancy protection**
- ✅ **Pausable** (deposits only - withdrawals always work)
- ✅ **Ownable** (simple ownership)
- ✅ **Emergency sweep** (recover stuck tokens)
- ✅ **Gas optimized**

## 📋 Functions

| Function | Description |
|----------|-------------|
| `deposit(assets, receiver)` | Deposit assets, get shares |
| `mint(shares, receiver)` | Mint exact shares |
| `withdraw(assets, receiver, owner)` | Withdraw exact assets |
| `redeem(shares, receiver, owner)` | Redeem exact shares |
| `sharePrice()` | Current price (assets per share) |
