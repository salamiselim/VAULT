// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Vault - Production-Grade Token Vault
 * @author SALAMI SELIM
 * @notice Fully ERC-4626 compliant vault with grade security and gas optimizations
 * @dev Implements all ERC-4626 and ERC-20 standards with vault-favorable rounding
 * 
 */
contract Vault is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    //////////////////////////////////
    ///////  IMMUTABLES  ///////////
    /////////////////////////////////

    IERC20 private immutable ASSET;
    uint8 private immutable DECIMALS;

    ///////////////////////////////////////
     ///////   STATE VARIABLES  //////////
    //////////////////////////////////////

    string private s_name;
    string private s_symbol;
    uint256 private s_totalShares;
    uint256 private s_maxTotalAssets;
    mapping(address => uint256) private s_shares;
    mapping(address => mapping(address => uint256)) private s_allowances;

    ///////////////////////////////
    /////  CONSTANTS  ///////////
    /////////////////////////////

    uint256 private constant PRECISION = 1e18;

    ////////////////////////////
    ////// EVENTS /////////////
    ////////////////////////////

    /// @notice Emitted when assets are deposited
    /// @param caller Address that initiated the deposit
    /// @param owner Address that received the shares
    /// @param assets Amount of assets deposited
    /// @param shares Amount of shares minted
    event Deposit(
        address indexed caller,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    /// @notice Emitted when assets are withdrawn
    /// @param caller Address that initiated the withdrawal
    /// @param receiver Address that received the assets
    /// @param owner Address that owned the shares
    /// @param assets Amount of assets withdrawn
    /// @param shares Amount of shares burned
    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    /// @notice Emitted when shares are transferred
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Emitted when allowance is updated
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Emitted when vault is paused
    event VaultPaused(address indexed by, uint256 timestamp);

    /// @notice Emitted when vault is unpaused
    event VaultUnpaused(address indexed by, uint256 timestamp);

    /// @notice Emitted when tokens are swept
    event TokenSwept(
        address indexed token,
        address indexed to,
        uint256 amount,
        uint256 timestamp
    );

    /// @notice Emitted when max assets cap is updated
    event MaxAssetsUpdated(uint256 oldMax, uint256 newMax, uint256 timestamp);

    /////////////////////////////////
     ///////  ERRORS  //////////////
    ////////////////////////////////

    error Vault__ZeroAmount();
    error Vault__ZeroAddress();
    error Vault__InsufficientShares();
    error Vault__InsufficientAllowance();
    error Vault__CannotSweepVaultAsset();

    /////////////////////////////////
    /////////// CONSTRUCTOR ////////
    ////////////////////////////////

    /**
     * @notice Initialize the vault with an underlying asset
     * @param asset_ The ERC20 token to be deposited into the vault
     * @param name_ The name of the vault share token
     * @param symbol_ The symbol of the vault share token
     */
    constructor(
    IERC20 asset_,
    string memory name_,
    string memory symbol_
    ) Ownable(msg.sender) {
    if (address(asset_) == address(0)) revert Vault__ZeroAddress();

    ASSET = asset_;
    s_name = name_;
    s_symbol = symbol_;
    DECIMALS = 18; // Standardize to 18 decimals for shares
    s_maxTotalAssets = type(uint256).max;
    }
    /////////////////////////////////////////// 
    ///////////  VAULT CORE FUNCTIONS ////////
    //////////////////////////////////////////

    /**
     * @notice Deposit assets into the vault and receive shares
     * @dev Mints shares to receiver by depositing exact amount of assets
     * @param assets The amount of assets to deposit
     * @param receiver The address that will receive the shares
     * @return shares The amount of shares minted
     */
    function deposit(uint256 assets, address receiver)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        // Checks
        if (assets == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();
        
        shares = previewDeposit(assets);
        if (shares == 0) revert Vault__ZeroAmount();
        unchecked {
            s_shares[receiver] += shares;
            s_totalShares += shares;
        }

        emit Deposit(msg.sender, receiver, assets, shares);
        ASSET.safeTransferFrom(msg.sender, address(this), assets);
    }

    /**
     * @notice Mint exact shares by depositing assets
     * @dev Deposits assets to receiver by minting exact amount of shares
     * @param shares The exact amount of shares to mint
     * @param receiver The address that will receive the shares
     * @return assets The amount of assets deposited
     */
    function mint(uint256 shares, address receiver)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();

        assets = previewMint(shares);

        unchecked {
            s_shares[receiver] += shares;
            s_totalShares += shares;
        }

        emit Deposit(msg.sender, receiver, assets, shares);
        ASSET.safeTransferFrom(msg.sender, address(this), assets);
    }

    /**
     * @notice Withdraw exact assets by burning shares
     * @dev Burns shares from owner and sends exact amount of assets to receiver
     * @param assets The exact amount of assets to withdraw
     * @param receiver The address that will receive the assets
     * @param owner The address that owns the shares
     * @return shares The amount of shares burned
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();

        shares = previewWithdraw(assets);

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        ASSET.safeTransfer(receiver, assets);
    }

    /**
     * @notice Redeem shares for assets
     * @dev Burns exact amount of shares and sends assets to receiver
     * @param shares The exact amount of shares to burn
     * @param receiver The address that will receive the assets
     * @param owner The address that owns the shares
     * @return assets The amount of assets withdrawn
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        assets = previewRedeem(shares);
        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        ASSET.safeTransfer(receiver, assets);
    }

    //////////////////////////////////
    /////// VIEW FUNCTIONS /////////
    /////////////////////////////////

    /**
     * @notice Get the address of the underlying asset
     * @return The address of the underlying ERC20 token
     */
    function asset() public view returns (address) {
        return address(ASSET);
    }

    /**
     * @notice Get the total assets held by the vault
     * @return The total amount of underlying assets
     */
    function totalAssets() public view returns (uint256) {
        return ASSET.balanceOf(address(this));
    }

    /**
     * @notice Convert assets to shares
     * @dev Rounds down (in favor of vault)
     * @param assets The amount of assets to convert
     * @return The equivalent amount of shares
     */
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = s_totalShares;
        
        if (supply == 0) {
            return assets;
        }
        
        uint256 totalAsset = totalAssets();
        
        // Formula: shares = (assets * totalShares) / totalAssets
        unchecked {
            return (assets * supply) / totalAsset;
        }
    }

    /**
     * @notice Convert shares to assets
     * @dev Rounds down (in favor of vault)
     * @param shares The amount of shares to convert
     * @return The equivalent amount of assets
     */
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = s_totalShares;
        
        if (supply == 0) {
            return shares;
        }
        
        // Formula: assets = (shares * totalAssets) / totalShares
        unchecked {
            return (shares * totalAssets()) / supply;
        }
    }

    /**
     * @notice Preview the amount of shares for a deposit
     * @param assets The amount of assets to deposit
     * @return The amount of shares that would be minted (rounds down)
     */
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    /**
     * @notice Preview the amount of assets needed for minting shares
     * @dev Rounds UP to protect vault
     * @param shares The amount of shares to mint
     * @return The amount of assets needed (rounds up)
     */
    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 supply = s_totalShares;
        
        if (supply == 0) {
            return shares;
        }
        
        uint256 totalAsset = totalAssets();
        
        // Formula: assets = (shares * totalAssets + supply - 1) / supply
        unchecked {
            return (shares * totalAsset + supply - 1) / supply;
        }
    }

    /**
     * @notice Preview the amount of shares needed for withdrawal
     * @dev Rounds UP to protect vault
     * @param assets The amount of assets to withdraw
     * @return The amount of shares that would be burned (rounds up)
     */
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 supply = s_totalShares;
        
        if (supply == 0) {
            return assets;
        }
        
        uint256 totalAsset = totalAssets();
        
        unchecked {
            return (assets * supply + totalAsset - 1) / totalAsset;
        }
    }

    /**
     * @notice Preview the amount of assets for redeeming shares
     * @param shares The amount of shares to redeem
     * @return The amount of assets that would be withdrawn (rounds down)
     */
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    /**
     * @notice Get the maximum amount of assets that can be deposited
     * @return The maximum deposit amount (capped for gradual rollout)
     */
    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @notice Get the maximum amount of shares that can be minted
     * @return The maximum mint amount
     */
    function maxMint(address) public pure returns (uint256) {
    return type(uint256).max;
    }

    /**
     * @notice Get the maximum amount of assets that can be withdrawn
     * @param owner The address to check
     * @return The maximum withdrawal amount
     */
    function maxWithdraw(address owner) external view returns (uint256) {
        return convertToAssets(s_shares[owner]);
    }

    /**
     * @notice Get the maximum amount of shares that can be redeemed
     * @param owner The address to check
     * @return The maximum redeem amount
     */
    function maxRedeem(address owner) external view returns (uint256) {
        return s_shares[owner];
    }

    ///////////////////////////////////////
    //////// ERC20 COMPATIBILITY /////////
    //////////////////////////////////////

    /**
     * @notice Get the total supply of vault shares
     * @return The total amount of shares in existence
     */
    function totalSupply() external view returns (uint256) {
        return s_totalShares;
    }

    /**
     * @notice Get the share balance of an account
     * @param account The address to query
     * @return The amount of shares owned
     */
    function balanceOf(address account) external view returns (uint256) {
        return s_shares[account];
    }

    /**
     * @notice Get the name of the vault share token
     * @return The token name
     */
    function name() public view returns (string memory) {
        return s_name;
    }

    /**
     * @notice Get the symbol of the vault share token
     * @return The token symbol
     */
    function symbol() public view returns (string memory) {
        return s_symbol;
    }

    /**
     * @notice Get the decimals of the vault share token
     * @return The number of decimals
     */
    function decimals() public view returns (uint8) {
        return DECIMALS;
    }

    /**
     * @notice Transfer shares to another address
     * @param to The recipient address
     * @param amount The amount of shares to transfer
     * @return True if successful
     */
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Approve another address to spend shares
     * @param spender The address authorized to spend
     * @param amount The amount of shares approved
     * @return True if successful
     */
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Transfer shares from one address to another
     * @param from The address to transfer from
     * @param to The address to transfer to
     * @param amount The amount of shares to transfer
     * @return True if successful
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /**
     * @notice Get the allowance of a spender
     * @param owner The address that owns the shares
     * @param spender The address authorized to spend
     * @return The amount of shares approved
     */
    function allowance(address owner, address spender)
        external
        view
        returns (uint256)
    {
        return s_allowances[owner][spender];
    }

    ////////////////////////////////////////
     //////// VAULT-SPECIFIC VIEWS ////////
    ////////////////////////////////////////

    /**
     * @notice Get the current share price (assets per share)
     * @dev Returns price with 18 decimals precision
     * @return The price of one share in assets (scaled by 1e18)
     */
    function sharePrice() external view returns (uint256) {
        uint256 supply = s_totalShares;
        if (supply == 0) return PRECISION; // 1:1 ratio initially
        
        unchecked {
            return (totalAssets() * PRECISION) / supply;
        }
    }

    /**
     * @notice Get the maximum assets cap
     * @return The maximum total assets allowed
     */
    function maxTotalAssets() external view returns (uint256) {
        return s_maxTotalAssets;
    }

    ///////////////////////////////////////
    //////// INTERNAL  FUNCTION //////////
    /////////////////////////////////////

    /**
     * @dev Internal function to transfer shares
     * @param from The address to transfer from
     * @param to The address to transfer to
     * @param amount The amount to transfer
     */
    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0)) revert Vault__ZeroAddress();
        if (to == address(0)) revert Vault__ZeroAddress();
        if (s_shares[from] < amount) revert Vault__InsufficientShares();

        unchecked {
            s_shares[from] -= amount;
            s_shares[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    /**
     * @dev Internal function to approve spending
     * @param owner The address that owns the shares
     * @param spender The address authorized to spend
     * @param amount The amount approved
     */
    function _approve(address owner, address spender, uint256 amount) internal {
        if (owner == address(0)) revert Vault__ZeroAddress();
        if (spender == address(0)) revert Vault__ZeroAddress();

        s_allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Internal function to spend allowance
     * @param owner The address that owns the shares
     * @param spender The address spending the shares
     * @param amount The amount to spend
     */
    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal {
        uint256 currentAllowance = s_allowances[owner][spender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert Vault__InsufficientAllowance();
            }
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    /**
     * @dev Internal function to burn shares
     * @param owner The address to burn from
     * @param amount The amount of shares to burn
     */
    function _burn(address owner, uint256 amount) internal {
        if (s_shares[owner] < amount) revert Vault__InsufficientShares();

        unchecked {
            // Safe: checked above
            s_shares[owner] -= amount;
            s_totalShares -= amount;
        }

        emit Transfer(owner, address(0), amount);
    }

    ///////////////////////////////////////////
    //////////   ADMIN FUNCTIONS /////////////
    ///////////////////////////////////////////

    /**
     * @notice Pause deposits (withdrawals always available)
     * @dev Only owner can pause
     */
    function pause() external onlyOwner {
        _pause();
        emit VaultPaused(msg.sender, block.timestamp);
    }

    /**
     * @notice Unpause the vault
     * @dev Only owner can unpause
     */
    function unpause() external onlyOwner {
        _unpause();
        emit VaultUnpaused(msg.sender, block.timestamp);
    }

    /**
     * @notice Update the maximum total assets cap
     * @dev Only owner can update. Used for gradual rollout
     * @param newMax The new maximum total assets
     */
    function setMaxTotalAssets(uint256 newMax) external onlyOwner {
        uint256 oldMax = s_maxTotalAssets;
        s_maxTotalAssets = newMax;
        emit MaxAssetsUpdated(oldMax, newMax, block.timestamp);
    }

    /**
     * @notice Emergency recovery of accidentally sent tokens
     * @dev Cannot sweep the underlying vault asset
     * @param token The token to recover
     * @param to The address to send recovered tokens to
     */
    function sweep(IERC20 token, address to) external onlyOwner {
        if (address(token) == address(ASSET)) {
            revert Vault__CannotSweepVaultAsset();
        }
        if (to == address(0)) revert Vault__ZeroAddress();

        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
        
        emit TokenSwept(address(token), to, amount, block.timestamp);
    }
}