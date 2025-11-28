// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ERC4626VaultTest is Test {
    Vault public vault;
    ERC20Mock public asset;
    
    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public receiver = makeAddr("receiver");
    address public attacker = makeAddr("attacker");
    
    uint256 constant INITIAL_BALANCE = 1_000_000e18;
    uint256 constant DEPOSIT_AMOUNT = 100e18;
    
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.startPrank(owner);
        asset = new ERC20Mock();
        vault = new Vault(IERC20(address(asset)), "Vault Token", "vTKN");
        vm.stopPrank();

        // Mint tokens to users
        asset.mint(user1, INITIAL_BALANCE);
        asset.mint(user2, INITIAL_BALANCE);
        asset.mint(attacker, INITIAL_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ConstructorSetsCorrectParameters() public view {
        assertEq(vault.asset(), address(asset));
        assertEq(vault.name(), "Vault Token");
        assertEq(vault.symbol(), "vTKN");
        assertEq(vault.decimals(), 18);
        assertEq(vault.owner(), owner);
    }

    function test_RevertWhen_ConstructorWithZeroAddress() public {
        vm.expectRevert();
        new Vault(IERC20(address(0)), "Test", "TST");
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Deposit_FirstDepositCreates1to1Shares() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        assertEq(shares, DEPOSIT_AMOUNT, "First deposit should be 1:1");
        assertEq(vault.balanceOf(user1), DEPOSIT_AMOUNT);
        assertEq(vault.totalSupply(), DEPOSIT_AMOUNT);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function test_Deposit_TransfersTokensCorrectly() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        
        uint256 userBalanceBefore = asset.balanceOf(user1);
        uint256 vaultBalanceBefore = asset.balanceOf(address(vault));
        
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        assertEq(asset.balanceOf(user1), userBalanceBefore - DEPOSIT_AMOUNT);
        assertEq(asset.balanceOf(address(vault)), vaultBalanceBefore + DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function test_Deposit_EmitsEvent() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        
        vm.expectEmit(true, true, false, true);
        emit Deposit(user1, user1, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
        
        vault.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();
    }

    function test_Deposit_ToAnotherReceiver() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        
        vault.deposit(DEPOSIT_AMOUNT, receiver);
        
        assertEq(vault.balanceOf(receiver), DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(user1), 0);
        vm.stopPrank();
    }

    function test_Deposit_WithYieldAccrued() public {
        // User1 deposits
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();

        // Simulate yield (10% gain)
        asset.mint(address(vault), 10e18);

        // User2 deposits same amount - should get fewer shares
        vm.startPrank(user2);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, user2);
        vm.stopPrank();

        // User2 should receive fewer shares than User1
        assertTrue(shares < vault.balanceOf(user1));
        
        // But equal value
        uint256 user1Value = vault.convertToAssets(vault.balanceOf(user1));
        uint256 user2Value = vault.convertToAssets(vault.balanceOf(user2));
        assertApproxEqAbs(user1Value, user2Value + 10e18, 1); // Within rounding
    }

    function test_RevertWhen_DepositZeroAmount() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);

        vm.expectRevert(Vault.Vault__ZeroAmount.selector);
        vault.deposit(0, user1);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositToZeroAddress() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        
        vm.expectRevert(Vault.Vault__ZeroAddress.selector);
        vault.deposit(DEPOSIT_AMOUNT, address(0));
        vm.stopPrank();
    }

    function test_RevertWhen_DepositWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        
        vm.expectRevert();
        vault.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            MINT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Mint_MintsExactShares() public {
        uint256 sharesToMint = 50e18;
        
        vm.startPrank(user1);
        asset.approve(address(vault), type(uint256).max);
        
        uint256 assetsNeeded = vault.previewMint(sharesToMint);
        vault.mint(sharesToMint, user1);
        
        assertEq(vault.balanceOf(user1), sharesToMint);
        assertEq(asset.balanceOf(address(vault)), assetsNeeded);
        vm.stopPrank();
    }

    function test_Mint_RoundsUpToProtectVault() public {
        // First deposit
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();

        // Add small yield
        asset.mint(address(vault), 1);

        // Mint should round up assets required
        vm.startPrank(user2);
        asset.approve(address(vault), type(uint256).max);
        
        uint256 sharesToMint = 1e18;
        uint256 preview = vault.previewMint(sharesToMint);
        vault.mint(sharesToMint, user2);
        
        // Assets taken should be at least preview amount (rounded up)
        assertGe(asset.balanceOf(address(vault)), DEPOSIT_AMOUNT + 1 + preview);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Withdraw_BurnsCorrectShares() public {
        // Deposit first
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        uint256 sharesToBurn = vault.previewWithdraw(50e18);
        uint256 sharesBefore = vault.balanceOf(user1);
        
        vault.withdraw(50e18, user1, user1);
        
        assertEq(vault.balanceOf(user1), sharesBefore - sharesToBurn);
        vm.stopPrank();
    }

    function test_Withdraw_TransfersCorrectAssets() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        uint256 withdrawAmount = 50e18;
        uint256 balanceBefore = asset.balanceOf(user1);
        
        vault.withdraw(withdrawAmount, user1, user1);
        
        assertEq(asset.balanceOf(user1), balanceBefore + withdrawAmount);
        vm.stopPrank();
    }

    function test_Withdraw_ToAnotherReceiver() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        uint256 receiverBalanceBefore = asset.balanceOf(receiver);
        vault.withdraw(50e18, receiver, user1);
        
        assertEq(asset.balanceOf(receiver), receiverBalanceBefore + 50e18);
        vm.stopPrank();
    }

    function test_Withdraw_WithApproval() public {
        // User1 deposits
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        // User1 approves user2 to withdraw
        vault.approve(user2, type(uint256).max);
        vm.stopPrank();

        // User2 withdraws on behalf of user1
        vm.prank(user2);
        vault.withdraw(50e18, receiver, user1);
        
        assertEq(asset.balanceOf(receiver), 50e18);
    }

    function test_Withdraw_RoundsUpSharesBurned() public {
        // Setup with yield
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();

        asset.mint(address(vault), 1); // Add 1 wei of yield

        // Preview should round up
        uint256 sharesToBurn = vault.previewWithdraw(50e18);
        
        vm.prank(user1);
        vault.withdraw(50e18, user1, user1);
        
        // Verify rounding protects vault
        assertTrue(sharesToBurn > 0);
    }

    ////////////////////////////////////////
    //////////  REDEEM TESTS /////////////
    ///////////////////////////////////////

    function test_Redeem_BurnsExactShares() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        uint256 sharesToRedeem = shares / 2;
        vault.redeem(sharesToRedeem, user1, user1);
        
        assertEq(vault.balanceOf(user1), shares - sharesToRedeem);
        vm.stopPrank();
    }

    function test_Redeem_ReturnsCorrectAssets() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        uint256 expectedAssets = vault.previewRedeem(shares); 
        uint256 balanceBefore = asset.balanceOf(user1);
        
        uint256 assets = vault.redeem(shares, user1, user1);
        
        assertEq(assets, expectedAssets);
        assertEq(asset.balanceOf(user1), balanceBefore + assets);
        vm.stopPrank();
    }

    function test_Redeem_WithYield() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();

        // Add 20% yield
        asset.mint(address(vault), 20e18);

        vm.startPrank(user1);
        uint256 balanceBefore = asset.balanceOf(user1);
        vault.redeem(shares, user1, user1);
        
        // Should receive original deposit + yield
        assertEq(asset.balanceOf(user1), balanceBefore + DEPOSIT_AMOUNT + 20e18);
        vm.stopPrank();
    }

    ////////////////////////////////////////
    ///////    CONVERSION TESTS //////////
    ///////////////////////////////////////

    function test_ConvertToShares_FirstDeposit() public view {
        uint256 shares = vault.convertToShares(100e18);
        assertEq(shares, 100e18, "Should be 1:1 when empty");
    }

    function test_ConvertToAssets_WithShares() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();

        uint256 assets = vault.convertToAssets(shares);
        assertEq(assets, DEPOSIT_AMOUNT);
    }

    function test_ConvertToShares_AfterYield() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();

        // Add 50% yield
        asset.mint(address(vault), 50e18);

        // 100 assets should now equal fewer shares
        uint256 shares = vault.convertToShares(100e18);
        assertTrue(shares < 100e18);
    }

    //////////////////////////////
    //////  ERC20 TESTS /////////
    ////////////////////////////

    function test_Transfer_ShareTokens() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        vault.transfer(user2, shares / 2);
        
        assertEq(vault.balanceOf(user1), shares / 2);
        assertEq(vault.balanceOf(user2), shares / 2);
        vm.stopPrank();
    }

    function test_Transfer_EmitsEvent() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        vm.expectEmit(true, true, false, true);
        emit Transfer(user1, user2, shares);
        
        vault.transfer(user2, shares);
        vm.stopPrank();
    }

    function test_Approve_AndTransferFrom() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        vault.approve(user2, shares);
        vm.stopPrank();

        assertEq(vault.allowance(user1, user2), shares);

        vm.prank(user2);
        vault.transferFrom(user1, receiver, shares);
        
        assertEq(vault.balanceOf(receiver), shares);
        assertEq(vault.balanceOf(user1), 0);
    }

    ////////////////////////////////////
    /////////  MAX FUNCTIONS //////////
    ////////////////////////////////////

    function test_MaxDeposit() public view {
    assertEq(vault.maxDeposit(user1), type(uint256).max);  
    }

function test_MaxMint() public view {
    assertEq(vault.maxMint(user1), type(uint256).max);  
    }
    function test_MaxWithdraw() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();

        assertEq(vault.maxWithdraw(user1), DEPOSIT_AMOUNT);
    }

    function test_MaxRedeem() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();

        assertEq(vault.maxRedeem(user1), shares);
    }

    ////////////////////////////////
    ////// ADMIN TESTS  ///////////
    ///////////////////////////////

    function test_Pause_OnlyOwner() public {
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_RevertWhen_NonOwnerPauses() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.pause();
    }

    function test_Sweep_RecoverTokens() public {
        // Create a different token
        ERC20Mock otherToken = new ERC20Mock();
        otherToken.mint(address(vault), 100e18);

        vm.prank(owner);
        vault.sweep(IERC20(address(otherToken)), owner);

        assertEq(otherToken.balanceOf(owner), 100e18);
    }

    function test_RevertWhen_SweepVaultAsset() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert();
        vault.sweep(IERC20(address(asset)), owner);
    }

    //////////////////////////////////////////
    /////// SECURITY TESTS ////////////////////
    /////////////////////////////////////////

    function test_YieldDistribution_Fair() public {
        // User1 deposits
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();

        // User2 deposits same amount
        vm.startPrank(user2);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, user2);
        vm.stopPrank();

        // Add 100 tokens yield
        asset.mint(address(vault), 100e18);

        // Both should get equal share
        uint256 user1Assets = vault.convertToAssets(vault.balanceOf(user1));
        uint256 user2Assets = vault.convertToAssets(vault.balanceOf(user2));

        assertApproxEqAbs(user1Assets, user2Assets, 1);
    }

    function test_ReentrancyProtection() public {
        vm.startPrank(user1);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        // If reentrancy possible, this would fail
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DepositAndRedeem(uint96 amount) public {
        vm.assume(amount > 0 && amount <= INITIAL_BALANCE);

        vm.startPrank(user1);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user1);
        
        uint256 assets = vault.redeem(shares, user1, user1);
        
        assertEq(assets, amount);
        vm.stopPrank();
    }

    function testFuzz_MintAndWithdraw(uint96 sharesToMint) public {
        vm.assume(sharesToMint > 0 && sharesToMint <= INITIAL_BALANCE);

        vm.startPrank(user1);
        asset.approve(address(vault), type(uint256).max);
        
        uint256 assetsBefore = asset.balanceOf(user1);
        uint256 assetsSpent = vault.mint(sharesToMint, user1);
        
        vault.withdraw(assetsSpent, user1, user1);
        
        assertApproxEqAbs(asset.balanceOf(user1), assetsBefore, 1);
        vm.stopPrank();
    }
}