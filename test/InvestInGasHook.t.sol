// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {InvestInGasHook} from "../src/InvestInGasHook.sol";
import {LiFiBridger} from "../src/LiFiBridger.sol";

// Mock PoolManager for isolated testing
contract MockPoolManager {
    function unlock(bytes calldata) external returns (bytes memory) {
        return "";
    }
}

// Mock WETH for testing
contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

// Mock USDC for testing
contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

/**
 * @title InvestInGasHookTest
 * @notice Isolated unit tests for InvestInGasHook
 * @dev Tests access control and configuration without full pool setup
 */
contract InvestInGasHookTest is Test {
    InvestInGasHook hook;
    MockPoolManager mockPoolManager;
    MockUSDC usdc;
    MockWETH weth;
    LiFiBridger bridger;

    address owner = address(1);
    address relayer = address(2);
    address user = address(3);

    function setUp() public {
        // Deploy mocks
        mockPoolManager = new MockPoolManager();
        usdc = new MockUSDC();
        weth = new MockWETH();

        // Deploy hook with correct flags for address
        address hookFlags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^
                (0x4444 << 144)
        );

        // Deploy hook via deployCodeTo
        bytes memory constructorArgs = abi.encode(
            address(mockPoolManager),
            address(usdc),
            address(weth),
            relayer,
            owner
        );
        deployCodeTo(
            "InvestInGasHook.sol:InvestInGasHook",
            constructorArgs,
            hookFlags
        );
        hook = InvestInGasHook(hookFlags);

        // Deploy bridger (with mock LiFi diamond address)
        bridger = new LiFiBridger(address(weth), address(0xdead), owner);

        // Configure
        vm.prank(owner);
        hook.setLiFiBridger(address(bridger));

        vm.prank(owner);
        bridger.setHook(address(hook));

        // Labels
        vm.label(address(hook), "InvestInGasHook");
        vm.label(address(usdc), "USDC");
        vm.label(address(weth), "WETH");
        vm.label(address(bridger), "LiFiBridger");
    }

    // ============ Access Control Tests ============

    function testOnlyRelayerCanPurchase() public {
        usdc.mint(user, 100e6);

        vm.prank(user);
        usdc.approve(address(hook), 100e6);

        // Non-relayer should revert
        vm.prank(user);
        vm.expectRevert(InvestInGasHook.NotRelayer.selector);
        hook.purchasePosition(100e6, 0, 50 gwei, "sepolia", 30 days, user);
    }

    function testOnlyRelayerCanRedeem() public {
        vm.prank(user);
        vm.expectRevert(InvestInGasHook.NotRelayer.selector);
        hook.redeemPosition(0, 1 ether, "", user);
    }

    function testOnlyOwnerCanSetRelayer() public {
        vm.prank(user);
        vm.expectRevert(InvestInGasHook.NotOwner.selector);
        hook.setRelayer(user);

        vm.prank(owner);
        hook.setRelayer(user);
        assertEq(hook.relayer(), user);
    }

    function testOnlyOwnerCanSetLiFiBridger() public {
        vm.prank(user);
        vm.expectRevert(InvestInGasHook.NotOwner.selector);
        hook.setLiFiBridger(user);
    }

    function testOnlyOwnerCanWithdrawFees() public {
        vm.prank(user);
        vm.expectRevert(InvestInGasHook.NotOwner.selector);
        hook.withdrawFees(user);
    }

    function testOnlyOwnerCanAddChain() public {
        vm.prank(user);
        vm.expectRevert(InvestInGasHook.NotOwner.selector);
        hook.addChain("optimism", 11155420);
    }

    // ============ Chain Configuration Tests ============

    function testDefaultChainIds() public view {
        assertEq(hook.chainIds("sepolia"), 11155111);
        assertEq(hook.chainIds("arbitrum"), 421614);
        assertEq(hook.chainIds("base"), 84532);
        assertEq(hook.chainIds("polygon"), 80002);
    }

    function testAddChain() public {
        vm.prank(owner);
        hook.addChain("optimism", 11155420);
        assertEq(hook.chainIds("optimism"), 11155420);
    }

    function testInvalidChainReverts() public {
        usdc.mint(user, 100e6);

        vm.prank(user);
        usdc.approve(address(hook), 100e6);

        vm.prank(relayer);
        vm.expectRevert(InvestInGasHook.InvalidChain.selector);
        hook.purchasePosition(
            100e6,
            0,
            50 gwei,
            "invalid_chain",
            30 days,
            user
        );
    }

    // ============ Protocol Fee Tests ============

    function testProtocolFee() public view {
        // Protocol fee should be 0.5% (50 basis points)
        assertEq(hook.PROTOCOL_FEE_BPS(), 50);
    }

    function testExpiryRefundFee() public view {
        // Expiry refund fee should be 2% (200 basis points)
        assertEq(hook.EXPIRY_REFUND_FEE_BPS(), 200);
    }

    function testMaxSlippage() public view {
        // Max slippage should be 1% (100 basis points)
        assertEq(hook.MAX_SLIPPAGE_BPS(), 100);
    }

    // ============ Immutable State Tests ============

    function testImmutableState() public view {
        assertEq(address(hook.purchaseToken()), address(usdc));
        assertEq(address(hook.weth()), address(weth));
        assertEq(hook.owner(), owner);
        assertEq(hook.relayer(), relayer);
    }

    // ============ Position View Tests ============

    function testGetPositionReturnsEmptyForNonExistent() public view {
        InvestInGasHook.GasPosition memory pos = hook.getPosition(999);
        assertEq(pos.wethAmount, 0);
        assertEq(pos.remainingWethAmount, 0);
        assertEq(pos.lockedGasPriceWei, 0);
    }

    function testGetGasUnitsAvailable() public view {
        // Non-existent position should return 0
        assertEq(hook.getGasUnitsAvailable(999), 0);
    }

    // ============ Event Tests ============

    function testRelayerUpdatedEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit InvestInGasHook.RelayerUpdated(relayer, user);
        hook.setRelayer(user);
    }

    function testLiFiBridgerUpdatedEvent() public {
        address newBridger = address(0x1234);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit InvestInGasHook.LiFiBridgerUpdated(address(bridger), newBridger);
        hook.setLiFiBridger(newBridger);
    }

    // ============ Zero Amount Tests ============

    function testZeroAmountPurchaseReverts() public {
        vm.prank(relayer);
        vm.expectRevert(InvestInGasHook.ZeroAmount.selector);
        hook.purchasePosition(0, 0, 50 gwei, "sepolia", 30 days, user);
    }

    function testRedeemNonExistentPositionReverts() public {
        vm.prank(relayer);
        vm.expectRevert(); // ERC721NonexistentToken is thrown before other checks
        hook.redeemPosition(999, 1 ether, "", user);
    }
}

/**
 * @title LiFiBridgerTest
 * @notice Unit tests for LiFiBridger
 */
contract LiFiBridgerTest is Test {
    LiFiBridger bridger;
    MockWETH weth;

    address owner = address(1);
    address hook = address(2);
    address user = address(3);

    function setUp() public {
        weth = new MockWETH();
        bridger = new LiFiBridger(address(weth), address(0xdead), owner);

        vm.prank(owner);
        bridger.setHook(hook);
    }

    function testOnlyHookCanBridge() public {
        vm.prank(user);
        vm.expectRevert(LiFiBridger.NotHook.selector);
        bridger.bridgeToChain(1, 1 ether, user, "");
    }

    function testOnlyHookCanDirectTransfer() public {
        vm.prank(user);
        vm.expectRevert(LiFiBridger.NotHook.selector);
        bridger.directTransfer(1 ether, user);
    }

    function testOnlyOwnerCanSetHook() public {
        vm.prank(user);
        vm.expectRevert(LiFiBridger.NotOwner.selector);
        bridger.setHook(user);
    }

    function testOnlyOwnerCanEmergencyWithdrawETH() public {
        vm.prank(user);
        vm.expectRevert(LiFiBridger.NotOwner.selector);
        bridger.emergencyWithdrawETH(user);
    }

    function testOnlyOwnerCanEmergencyWithdrawToken() public {
        vm.prank(user);
        vm.expectRevert(LiFiBridger.NotOwner.selector);
        bridger.emergencyWithdrawToken(address(weth), user);
    }

    function testHookUpdatedEvent() public {
        address newHook = address(0x1234);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit LiFiBridger.HookUpdated(hook, newHook);
        bridger.setHook(newHook);
    }

    function testZeroAmountBridgeReverts() public {
        vm.prank(hook);
        vm.expectRevert(LiFiBridger.ZeroAmount.selector);
        bridger.bridgeToChain(1, 0, user, "");
    }

    function testZeroAmountDirectTransferReverts() public {
        vm.prank(hook);
        vm.expectRevert(LiFiBridger.ZeroAmount.selector);
        bridger.directTransfer(0, user);
    }
}
