// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TrvoToken} from "../src/TrvoToken.sol";
import {TokenSale} from "../src/TokenSale.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @dev ERC20 that calls back into a target (the sale) during transfer / transferFrom.
contract ReentrantToken is ERC20 {
    address public target;
    bytes public payload;
    bool public hookRan;
    bool public reentrySucceeded;
    bytes public reentryRevertData;

    constructor() ERC20("EVIL", "EVIL") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        hookRan = false;
    }

    function _hook() internal {
        if (target == address(0) || hookRan) return;
        hookRan = true;
        (bool ok, bytes memory ret) = target.call(payload);
        reentrySucceeded = ok;
        reentryRevertData = ret;
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        _hook();
        return super.transfer(to, amt);
    }

    function transferFrom(address from, address to, uint256 amt) public override returns (bool) {
        _hook();
        return super.transferFrom(from, to, amt);
    }
}

contract TokenSaleTest is Test {
    MockUSDC usdc;
    TrvoToken trvo;
    TokenSale sale;

    address treasury = makeAddr("treasuryVesting");
    address multisig = makeAddr("multisig");
    address liquidity = makeAddr("liquidity");
    uint256 start;
    uint256 end;

    function setUp() public {
        usdc = new MockUSDC();
        // Test-only supply (real supply is pending confirmation).
        trvo = new TrvoToken(address(this), 21_000_000e18);
        start = block.timestamp + 1 days;
        end = start + 14 days;
        trvo.approve(
            vm.computeCreateAddress(address(this), vm.getNonce(address(this))), 4_200_000e18
        );
        sale = new TokenSale(
            IERC20(address(usdc)), IERC20(address(trvo)), treasury, multisig, liquidity, start, end
        );
    }

    function _buy(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(sale), amt);
        sale.buy(amt);
        vm.stopPrank();
    }

    function _raise(uint256 buyers) internal {
        for (uint256 i = 0; i < buyers; i++) {
            _buy(address(uint160(1000 + i)), 500e6);
        }
    }

    function test_priceIsExact() public {
        vm.warp(start);
        address b = makeAddr("b");
        _buy(b, 1e6);
        assertEq(sale.purchased(b), 420e18);
    }

    function test_revertBeforeStartAndAfterEnd() public {
        usdc.mint(address(this), 1e6);
        usdc.approve(address(sale), 1e6);
        vm.expectRevert("not open");
        sale.buy(1e6);
        vm.warp(end);
        vm.expectRevert("not open");
        sale.buy(1e6);
    }

    function test_revertOverWalletCap() public {
        vm.warp(start);
        address b = makeAddr("b");
        _buy(b, 500e6);
        usdc.mint(b, 1e6);
        vm.startPrank(b);
        usdc.approve(address(sale), 1e6);
        vm.expectRevert("wallet cap");
        sale.buy(1e6);
        vm.stopPrank();
    }

    function test_refundWhenSoftCapMissed() public {
        vm.warp(start);
        address b = makeAddr("b");
        _buy(b, 100e6);
        vm.warp(end);
        assertTrue(sale.saleFailed());
        vm.prank(b);
        sale.refund();
        assertEq(usdc.balanceOf(b), 100e6);
        vm.prank(b);
        vm.expectRevert("already refunded");
        sale.refund();
        vm.expectRevert("soft cap missed");
        sale.finalize();
        sale.recoverFailedSaleTokens();
        assertEq(trvo.balanceOf(treasury), sale.TOKENS_FOR_SALE());
    }

    function test_finalizeAtSoftCap() public {
        vm.warp(start);
        _raise(10); // 5,000 USDC
        vm.warp(end);
        sale.finalize();
        assertEq(usdc.balanceOf(liquidity), 5_000e6);
        assertEq(usdc.balanceOf(multisig), 0);
        assertEq(trvo.balanceOf(treasury), sale.TOKENS_FOR_SALE() - 5_000e6 * 420e12);
        vm.expectRevert("finalized");
        sale.finalize();
    }

    function test_finalizeSurplusToMultisig() public {
        vm.warp(start);
        _raise(14); // 7,000 USDC
        vm.warp(end);
        sale.finalize();
        assertEq(usdc.balanceOf(liquidity), 5_000e6);
        assertEq(usdc.balanceOf(multisig), 2_000e6);
    }

    function test_noRefundAfterSuccess() public {
        vm.warp(start);
        _raise(10);
        vm.warp(end);
        sale.finalize();
        vm.prank(address(1000));
        vm.expectRevert("no refund");
        sale.refund();
    }

    function test_buyerVesting() public {
        vm.warp(start);
        _raise(10);
        vm.warp(end);
        sale.finalize();
        address b = address(1000);
        uint256 total = sale.purchased(b);
        vm.prank(b);
        sale.claim();
        assertEq(trvo.balanceOf(b), total / 4);
        vm.warp(block.timestamp + 90 days);
        assertEq(sale.vested(b), total / 4 + (total - total / 4) / 2);
        vm.warp(block.timestamp + 365 days);
        vm.prank(b);
        sale.claim();
        assertEq(trvo.balanceOf(b), total);
    }

    function test_claimBeforeFinalizeReverts() public {
        vm.warp(start);
        _buy(address(1000), 500e6);
        vm.prank(address(1000));
        vm.expectRevert("nothing");
        sale.claim();
    }

    function testFuzz_priceLinear(uint256 amt) public {
        amt = bound(amt, 1, 500e6);
        vm.warp(start);
        address b = makeAddr("f");
        _buy(b, amt);
        assertEq(sale.purchased(b), amt * 420e12);
    }

    // ---- F2: the sale is funded atomically in the constructor ----

    function test_saleFundedAtConstruction() public view {
        assertEq(trvo.balanceOf(address(sale)), sale.TOKENS_FOR_SALE());
    }

    function test_constructorRevertsWithoutAllowance() public {
        vm.expectRevert();
        new TokenSale(
            IERC20(address(usdc)), IERC20(address(trvo)), treasury, multisig, liquidity, start, end
        );
    }

    function test_constructorRevertsWhenDeployerUnderfunded() public {
        address poor = makeAddr("poor");
        trvo.transfer(poor, sale.TOKENS_FOR_SALE() - 1);
        vm.startPrank(poor);
        trvo.approve(vm.computeCreateAddress(poor, vm.getNonce(poor)), sale.TOKENS_FOR_SALE());
        vm.expectRevert();
        new TokenSale(
            IERC20(address(usdc)), IERC20(address(trvo)), treasury, multisig, liquidity, start, end
        );
        vm.stopPrank();
    }

    function test_f2_softCapMetAlwaysFinalizes() public {
        // Previously a sale funded late (or never) locked buyers' USDC once the soft cap was met.
        vm.warp(start);
        _raise(10);
        vm.warp(end);
        assertEq(trvo.balanceOf(address(sale)), sale.TOKENS_FOR_SALE());
        sale.finalize();
        assertTrue(sale.finalized());
        assertEq(usdc.balanceOf(address(sale)), 0);
    }

    // ---- Reentrancy: malicious tokens must not be able to re-enter the sale ----

    function _deploySale(IERC20 usdc_, IERC20 trvo_) internal returns (TokenSale s) {
        ReentrantToken(address(trvo_)).mint(address(this), 4_200_000e18);
        trvo_.approve(
            vm.computeCreateAddress(address(this), vm.getNonce(address(this))), 4_200_000e18
        );
        s = new TokenSale(usdc_, trvo_, treasury, multisig, liquidity, start, end);
    }

    function _buyWith(TokenSale s, ReentrantToken u, address who, uint256 amt) internal {
        u.mint(who, amt);
        vm.startPrank(who);
        u.approve(address(s), amt);
        s.buy(amt);
        vm.stopPrank();
    }

    function _assertBlocked(ReentrantToken t) internal view {
        assertTrue(t.hookRan(), "hook did not run");
        assertFalse(t.reentrySucceeded(), "reentry succeeded");
        assertEq(
            bytes4(t.reentryRevertData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector
        );
    }

    function test_reentrancy_buyViaTransferFrom() public {
        ReentrantToken evilUsdc = new ReentrantToken();
        TokenSale s = _deploySale(IERC20(address(evilUsdc)), IERC20(address(new ReentrantToken())));
        vm.warp(start);
        evilUsdc.arm(address(s), abi.encodeCall(TokenSale.buy, (1e6)));
        _buyWith(s, evilUsdc, makeAddr("b"), 1e6);
        _assertBlocked(evilUsdc);
        assertEq(s.totalRaised(), 1e6);
    }

    function test_reentrancy_refundViaTransfer() public {
        ReentrantToken evilUsdc = new ReentrantToken();
        TokenSale s = _deploySale(IERC20(address(evilUsdc)), IERC20(address(new ReentrantToken())));
        vm.warp(start);
        address b = makeAddr("b");
        _buyWith(s, evilUsdc, b, 100e6);
        vm.warp(end);
        evilUsdc.arm(address(s), abi.encodeCall(TokenSale.refund, ()));
        vm.prank(b);
        s.refund();
        _assertBlocked(evilUsdc);
        assertEq(evilUsdc.balanceOf(b), 100e6);
    }

    function test_reentrancy_finalizeViaTransfer() public {
        ReentrantToken evilUsdc = new ReentrantToken();
        TokenSale s = _deploySale(IERC20(address(evilUsdc)), IERC20(address(new ReentrantToken())));
        vm.warp(start);
        for (uint256 i = 0; i < 10; i++) {
            _buyWith(s, evilUsdc, address(uint160(1000 + i)), 500e6);
        }
        vm.warp(end);
        evilUsdc.arm(address(s), abi.encodeCall(TokenSale.finalize, ()));
        s.finalize();
        _assertBlocked(evilUsdc);
        assertEq(evilUsdc.balanceOf(liquidity), 5_000e6);
    }

    function test_reentrancy_claimViaTransfer() public {
        ReentrantToken evilUsdc = new ReentrantToken();
        ReentrantToken evilTrvo = new ReentrantToken();
        TokenSale s = _deploySale(IERC20(address(evilUsdc)), IERC20(address(evilTrvo)));
        vm.warp(start);
        for (uint256 i = 0; i < 10; i++) {
            _buyWith(s, evilUsdc, address(uint160(1000 + i)), 500e6);
        }
        vm.warp(end);
        s.finalize();
        address b = address(1000);
        evilTrvo.arm(address(s), abi.encodeCall(TokenSale.claim, ()));
        vm.prank(b);
        s.claim();
        _assertBlocked(evilTrvo);
        assertEq(evilTrvo.balanceOf(b), s.purchased(b) / 4);
    }

    function test_reentrancy_finalizeViaTrvoTransfer() public {
        ReentrantToken evilUsdc = new ReentrantToken();
        ReentrantToken evilTrvo = new ReentrantToken();
        TokenSale s = _deploySale(IERC20(address(evilUsdc)), IERC20(address(evilTrvo)));
        vm.warp(start);
        for (uint256 i = 0; i < 10; i++) {
            _buyWith(s, evilUsdc, address(uint160(1000 + i)), 500e6);
        }
        vm.warp(end);
        evilTrvo.arm(address(s), abi.encodeCall(TokenSale.finalize, ()));
        s.finalize();
        _assertBlocked(evilTrvo);
        assertTrue(s.finalized());
    }
}
