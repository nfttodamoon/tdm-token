// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.4;

/// Import libraries
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/// Import base contract from OpenZeppelin
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Import PancakeSwap interface
import "@pancakeswap-libs/pancake-swap-core/contracts/interfaces/IPancakeFactory.sol";
import "pancakeswap-peripheral/contracts/interfaces/IPancakeRouter02.sol";

/**
 * @title TODAMOON PancakeSwap Proxy Contract
 * 
 * @notice This contract is used to handle the logic involved in the swap and liquify of TODAMOON token via PancakeSwap.
 */
contract PancakeSwapProxy is Ownable {

    using SafeMath for uint256;
	using Address for address;

    /// Define the Pancakeswap contract interface
	IPancakeRouter02 public immutable pancakeswapV2Router;
	/// Record the Pancakeswap TDM-BUSD pair address
	address public immutable pancakeswapV2Pair;

    /// Define the TDM BEP20 token contract interface
    IERC20 public immutable tdm;
    /// Define the BUSD BEP20 token contract interface
	IERC20 public immutable busd;

    /// Define the TDM Ownable token contract interface
    Ownable public immutable tdmOwnable; 

    constructor() {
        /// Set Pancakeswap router address
		IPancakeRouter02 _pancakeswapV2Router = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
		// Create a Pancakeswap pair for TDM (i.e. the contract owner and creator) against BUSD
		pancakeswapV2Pair = IPancakeFactory(_pancakeswapV2Router.factory())
			.createPair(address(owner()), address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56));
		/// Set contract variables
		pancakeswapV2Router = _pancakeswapV2Router;
        /// Initialize TDM BEP20 token contract interface
        tdm = IERC20(owner()); // This contract should be created by the TDM token contract
        /// Initialize TDM Ownable contract interface
        tdmOwnable = Ownable(owner()); // This contract should be created by the TDM token contract
        /// Initialize BUSD BEP20 token contract interface
		busd = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    }

    /**
	 * @notice Swap TDM token owned by this contract into BUSD and provide liquidity to Pancakeswap
     * @return (
     *      uint256 - the amount of TDM token which was used to swap into BUSD,
     *      uint256 - the amount of BUSD token obtained from the swap and was put back into the swap,
     *      uint256 - the amount of TDM token which was put into the swap    
     * )
	 */
	function swapAndLiquify() external onlyOwner() returns (uint256, uint256, uint256) {
        /// Get current TDM token balance
        uint256 contractTokenBalance = tdm.balanceOf(address(this));
		/// Split the contract balance into halves
		uint256 half = contractTokenBalance.div(2);
		uint256 otherHalf = contractTokenBalance.sub(half);
		/// Capture the contract's current BUSD balance
		uint256 initialBalance = busd.balanceOf(address(this));
		/// Swap half of the tokens for BUSD
		swapTokensForBUSD(half);
		/// Calculate how much BUSD did we just swap into
		uint256 busdSwapped = busd.balanceOf(address(this)).sub(initialBalance);
		/// Add liquidity to pancakeswap
		addLiquidity(otherHalf, busdSwapped);
        /// Return the amount of TDM token swapped for BUSD, amount of BUSD we get from the swap, 
        /// and the amount of TDM token which was put into PancakeSwap
        return (half, busdSwapped, otherHalf);
	}

    /**
	 * @notice Swap TDM into BUSD
	 * @param tokenAmount amount of TDM to be swapped into BUSD
	 */
	function swapTokensForBUSD(uint256 tokenAmount) private {
		/// Generate the pancakeswap pair path of TDM -> BUSD
		address[] memory path = new address[](2);
		path[0] = address(tdm);
		path[1] = address(busd);
		/// Approve Pancakeswap router to spend tokenAmount of TDM from this contract
		tdm.approve(address(pancakeswapV2Router), tokenAmount);
		/// Make the swap
		pancakeswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
			tokenAmount,
			0, /// Accept any amount of BUSD
			path,
			address(this),
			block.timestamp
		);
	}

	/**
	 * @notice Add liquidity to the TDM-BUSD pool
	 * @param tokenAmount amount of TDM token to be supplied
	 * @param busdAmount amount BUSD to be supplied
	 */
	function addLiquidity(uint256 tokenAmount, uint256 busdAmount) private {
		/// Approve Pancakeswap to use 'tokenAmount' of TDM token from this contract
		tdm.approve(address(pancakeswapV2Router), tokenAmount);
		/// Approve Pancakeswap to use 'busdAmount' of BUSD from this contract
		busd.approve(address(pancakeswapV2Router), busdAmount);
		/// Add the liquidity
		pancakeswapV2Router.addLiquidity(
			address(tdm),
			address(busd),
			tokenAmount,
			busdAmount,
			0, /// Slippage is unavoidable, we will provide liqudity regardless of price
			0, /// Slippage is unavoidable, we will provide liqudity regardless of price
			tdmOwnable.owner(),
			block.timestamp
		);
	}

}