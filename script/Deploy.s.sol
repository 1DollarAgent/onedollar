// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {OneDollarToken} from "../src/OneDollarToken.sol";
import {OneDollarMint} from "../src/OneDollarMint.sol";
import {OneDollarMine} from "../src/OneDollarMine.sol";

/// @notice OneDollar ($1) two-stage deploy on BNB SMART CHAIN (56). NOT executed here. DEX = PancakeSwap V2,
///         pair = $1/USDT (created by the token constructor via the official factory), settlement = USDT (18-dec).
///         NO price oracle: 1 share == 1 USDT. Fee = 2% transfer tax on the pair (1% treasury + 1% auto-LP to DEAD)
///         realized by a capped swapback; 30%/120 s anti-snipe sell tax. Order:
///           1. token (creates the pair; nothing can move until genesis opens)
///           2. mint (genesis; the lpAdder: 10,000th share seeds 33,000,000 $1 + 8,000 USDT, LP -> DEAD, enableTrading)
///           3. mine (Stage 2)         4. token.initialize(mint, mine)
///           5. TREASURY: mint.seed(); mint.setPaused(false)
///
///         VERIFIED BSC MAINNET ADDRESSES (on-chain, 2026-11-10 via cast):
///           PancakeSwap V2 Factory 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73
///           PancakeSwap V2 Router  0x10ED43C718714eb63d5aA57B78B54704E256024E   (router.factory() == Factory)
///           USDT                   0x55d398326f99059fF775485246999027B3197955   (symbol "USDT", 18 DECIMALS)
///           WBNB                   0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c   (router.WETH(); unused by these contracts)
contract Deploy is Script {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    function run() external {
        address gateSigner = vm.envAddress("GATE_SIGNER");
        address treasury = vm.envAddress("TREASURY");
        uint256 mintStart = vm.envOr("MINT_START", uint256(0));
        require(block.chainid == 56, "deploy only on BNB Smart Chain");
        require(USDT.code.length > 0 && ROUTER.code.length > 0, "infra missing");

        vm.startBroadcast();
        OneDollarToken token = new OneDollarToken(USDT, ROUTER); // creates the $1/USDT pair
        OneDollarMint mint = new OneDollarMint(
            OneDollarMint.Config({token: address(token), usdt: USDT, gateSigner: gateSigner, treasury: treasury, mintStart: mintStart})
        );
        OneDollarMine mine = new OneDollarMine(address(token), USDT, ROUTER, address(mint), gateSigner);
        token.initialize(address(mint), address(mine));
        vm.stopBroadcast();

        console2.log("token", address(token));
        console2.log("pair ", token.pair());
        console2.log("mint ", address(mint));
        console2.log("mine ", address(mine));
        console2.log("-> TREASURY: mint.seed(); mint.setPaused(false). Genesis opens + locks the LP at share 10,000.");
    }
}
