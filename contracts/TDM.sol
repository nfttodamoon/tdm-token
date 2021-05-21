// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.4;

/// Import libraries
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/// Import base contract from OpenZeppelin
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Import PancakeSwapProxy contract
import "./PancakeSwapProxy.sol";

/**
 * @title TODAMOON Token Contract
 *
 * @notice This contract implements the TODAMOON token.
 */
contract TODAMOON is Context, IERC20, Ownable {
	
	using SafeMath for uint256;
	using Address for address;

	/// Record the amount of reflection owned by an address
	mapping (address => uint256) private _rOwned;
	/// Record the amount of "actual token" owned by an address
	/// Only used for address that are excluded from reflection reward
	/// It should be 0 for address that are not excluded
	mapping (address => uint256) private _tOwned;
	/// For ERC20 allowances mechancism
	mapping (address => mapping (address => uint256)) private _allowances;

	/// Record whether an address is excluded from paying the transaction tax
	/// If _isExcludedFromFee(address) = true, the address are exempted from transaction tax
	mapping (address => bool) private _isExcludedFromFee;

	/// Record whether an address is excluded from reflection reward
	/// If _isExcluded(address) = true, the address would not receive reflection reward
	mapping (address => bool) private _isExcluded;
	/// Another variable for storing address(es) that are excluded from reflection reward
	/// We need another variable since we need to loop over thses address(es) in _getCurrentSupply()
	address[] private _excluded;
   
	/// MAX is always the maximum integer represented by uint256 - 1
	uint256 private constant MAX = ~uint256(0);
	/// Define the maximum token supply which is 10 trillion TDM with 6 decimal places
	uint256 private constant _tTotal = 10 * 10**12 * 10**6;
	/// Define the initial maximum amount of reflection which should be the maximum
	/// integer that is divisible by _tTotal.
	/// It is because reflection ultimately represents certain underlying token balance
	/// and we want the conversion ratio between reflection and actual token to be an integer.
	uint256 private _rTotal = (MAX - (MAX % _tTotal));
	/// Record the total amount of token that was distributed to all owners due to transaction tax 
	uint256 private _tFeeTotal;

	/// Token name
	string private constant _name = "TODAMOON";
	/// Token symbol
	string private constant _symbol = "TDM";
	/// Decimal places used
	uint8 private constant _decimals = 6;
	
	/// Set TDM to distribute 5% of net transaction value to all owners
	uint256 public _taxFee = 5;
	/// Temp variable used in removeAllFee() and restoreAllFee()
	uint256 private _previousTaxFee = _taxFee;
	
	/// Set TDM to use 5% of net transaction value to provide liquidity
	uint256 public _liquidityFee = 5;
	/// Temp variable used in removeAllFee() and restoreAllFee()
	uint256 private _previousLiquidityFee = _liquidityFee;

	/// Define the PancakeSwapProxy interface
	PancakeSwapProxy public immutable pancakeSwapProxy;
	
	/// Used by swapAndLiquify() method to signal whether we are already providing liquidity
	/// so that we don't fall into an infinite loop in that method
	bool inSwapAndLiquify;
	/// Define whether the contract will use collected tax to provide liquidity onto the swap
	bool public swapAndLiquifyEnabled = true;
	
	/// Define that each transaction cannot exceeds 5% of token total supply to protect investor
	uint256 public _maxTxAmount = _tTotal.mul(5).div(100);
	/// Define the minimum amount of collected tax before we sent it to the swap to add liquidity
	/// It is set as 0.05% of total token supply to avoid excessive transaction cost
	uint256 private numTokensSellToAddToLiquidity = _tTotal.mul(5).div(10000);
	
	/// Event that will be emitted when an address is excluded or included in reflection reward
	event AddressExcludedFromRewardUpdated(address addressModified, bool isExcludedFromReward);
	/// Event that will be emitted when an address is excluded or included to pay transaction fee
	event AddressExcludedFromFeeUpdated(address addressModified, bool isExcludedFromFee);
	/// Event that will be emitted when the percentage of the net transaction value to be used to redistribute to token holders is updated
	event TransactionFeeUpdated(uint256 updatedTransactionFee);
	/// Event that will be emitted when the percentage of the net transaction value to be used to provide liquidity is updated
	event LiquidityFeeUpdated(uint256 updatedLiquidityFee);
	/// Event that will be emitted when the maximum transaction limit is updated
	event MaxTxAmountUpdated(uint256 updatedMaxTxAmount);
	/// Event that will be emitted when numTokensSellToAddToLiquidity is modified
	event MinTokensBeforeSwapUpdated(uint256 minTokensBeforeSwap);
	/// Event that will be emitted when swapAndLiquifyEnabled is modified
	event SwapAndLiquifyEnabledUpdated(bool enabled);
	/// Event that will be emitted when liquidity is provided to the swap
	event SwapAndLiquify(
		uint256 tokensSwapped,
		uint256 busdReceived,
		uint256 tokensIntoLiquidity
	);
	
	/// Modifier for preventing the contract from checking whether to provide liquidity when we are providing liquidity
	/// This is used to prevent an infinite loop
	modifier lockTheSwap {
		inSwapAndLiquify = true;
		_;
		inSwapAndLiquify = false;
	}

	/// ERC-20 Token Functions
	
	constructor() {
		/// Give deployer entire toke supply
		_rOwned[_msgSender()] = _rTotal;
		/// Initialize PancakeSwapProxy contract for swapping purposes
		pancakeSwapProxy = new PancakeSwapProxy();
		/// Exclude owner and this contract from fee
		_isExcludedFromFee[owner()] = true;
		_isExcludedFromFee[address(this)] = true;
		/// Emit Transfer event that signal all token has been transferred to the deployer
		emit Transfer(address(0), _msgSender(), _tTotal);
	}

	/**
	 * @notice Get the name of the token
	 * @return string name of the token
	 */
	function name() public pure returns (string memory) {
		return _name;
	}

	/**
	 * @notice Get the symbol of the token
	 * @return string symbol of the token
	 */
	function symbol() public pure returns (string memory) {
		return _symbol;
	}

	/**
	 * @notice Get the number of decimal place of the token
	 * @return uint8 number of decimal place of the token
	 */
	function decimals() public pure returns (uint8) {
		return _decimals;
	}

	/**
	 * @notice Get the total supply of the token
	 * @return uint256 total supply of the token
	 */
	function totalSupply() public pure override returns (uint256) {
		return _tTotal;
	}

	/**
	 * @notice Get the amount of token owned by an address
	 * @param account address to be checked
	 * @return uint256 amount of token owned by an address
	 */
	function balanceOf(address account) public view override returns (uint256) {
		/// For address excluded from reflection reward, their token balance is defined by the _tOwned variable
		if (_isExcluded[account]) return _tOwned[account];
		/// Otherwise, their token balance is defined by the amount of reflection they owned in the _rOwned variable
		return tokenFromReflection(_rOwned[account]);
	}

	/**
	 * @notice Moves 'amount' tokens from the caller's account to 'recipient'.
	 * @notice Emits a {Transfer} event after the transfer.
	 * @param recipient the recipient address of the token
	 * @param amount the amount of token to be transferred to the recipient
	 * @return bool a boolean indicating whether the operation succeeded.
	 */
	function transfer(address recipient, uint256 amount) public override returns (bool) {
		_transfer(_msgSender(), recipient, amount);
		return true;
	}

	/**
	 * @notice Returns the remaining number of tokens that 'spender' will be allowed to spend on behalf of 'owner' through {transferFrom}.
	 * @notice This is zero by default.
	 * @notice This value changes when {approve} or {transferFrom} are called.
	 * @param owner address which has allowed spender to spend their token
	 * @param spender address which can spend owner's token on their behalf
	 * @return uint256 the remaining number of tokens that 'spender' will be allowed to spend on behalf of 'owner'
	 */
	function allowance(address owner, address spender) public view override returns (uint256) {
		return _allowances[owner][spender];
	}

	/**
	 * @notice Sets 'amount' as the allowance of 'spender' over the caller's tokens.
	 * @notice Emits an {Approval} event.
	 * @param spender address which can spend caller's token on their behalf
	 * @param amount the amount of token that spender can spend on the caller's behalf
	 * @return bool a boolean indicating whether the operation succeeded.
	 */
	function approve(address spender, uint256 amount) public override returns (bool) {
		_approve(_msgSender(), spender, amount);
		return true;
	}

	/**
	 * @notice Moves 'amount' tokens from 'sender' to 'recipient' using the allowance mechanism
	 * @param sender address which sends the token
	 * @param recipient address that receives the token transferred
	 * @param amount the amount of token to be transferred
	 * @return bool a boolean indicating whether the operation succeeded.
	 */
	function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
		/// Transfer token from sender to recipient
		_transfer(sender, recipient, amount);
		/// Reduce the allowance that caller can spend on behalf of sender
		/// It should throw if the caller did not have enough allowance
		_approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
		return true;
	}

	/**
	 * @notice Increase the allowance of spender to spend caller's token by addedValue
	 * @param spender address which can spend caller's token on their behalf
	 * @param addedValue amount of token that spender can additionally spend on the caller's behalf
	 * @return bool a boolean indicating whether the operation succeeded.
	 */
	function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
		/// Increase allowance by addedValue
		_approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
		return true;
	}

	/**
	 * @notice Decrease the allowance of spender to spend caller's token by addedValue
	 * @param spender address which can spend caller's token on their behalf
	 * @param subtractedValue amount of allowance to be reduced
	 * @return bool a boolean indicating whether the operation succeeded.
	 */
	function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
		/// Decrease allowance by subtractedValue and throws if it drops below 0
		_approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
		return true;
	}

	/**
	 * @notice Get whether an account is excluded from reflection reward
	 * @param account address to be checked
	 * @return bool whether an account is excluded from reflection reward
	 */
	function isExcludedFromReward(address account) public view returns (bool) {
		return _isExcluded[account];
	}

	/**
	 * @notice Get the total amount of token that has been redistributed to holders via reflection
	 * @return uint256 the total amount of token that has been redistributed
	 */
	function totalFees() public view returns (uint256) {
		return _tFeeTotal;
	}

	/// Tokenomics Management Functions

	/**
	 * @notice Exclude an address from receiving reflection reward
	 * @param account address to be excluded
	 */
	function excludeFromReward(address account) external onlyOwner() {
		/// Do not exclude address that are already excluded
		require(!_isExcluded[account], "Account is already excluded");
		if(_rOwned[account] > 0) {
			/// Award the excluded address with _tOwned actual token that is equivalent to the amount of reflection it owned
			/// This is needed since excluded address can only transaction token owned as defined in the _tOwned variable
			_tOwned[account] = tokenFromReflection(_rOwned[account]);
		}
		/// Include the address in _isExcluded mapping and _excluded array
		_isExcluded[account] = true;
		_excluded.push(account);
		/// Emit AddressExcludedFromRewardUpdated event
		emit AddressExcludedFromRewardUpdated(account, true);
	}

	/**
	 * @notice Include an excluded address to receive reflection rewards.
	 * @notice Note that when an address is re-included, it will receive reflection rewards as if it was never excluded.
	 * @param account address to be included
	 */
	function includeInReward(address account) external onlyOwner() {
		/// Require the address to be currenrly excluded
		require(_isExcluded[account], "Account is not excluded");
		/// Loop over the _excluded array
		for (uint256 i = 0; i < _excluded.length; i++) {
			/// Look for the address in the _excluded array
			if (_excluded[i] == account) {
				/// Overwrite last excluded address to current address position
				_excluded[i] = _excluded[_excluded.length - 1];
				/// Set _tOwned to 0 since included address should use the reflection mechanism instead
				_tOwned[account] = 0;
				/// Set _isExcluded to false
				_isExcluded[account] = false;
				/// Pop the last excluded address since it has overwritten to current position already
				_excluded.pop();
				break;
			}
		}
		/// Emit AddressExcludedFromRewardUpdated event
		emit AddressExcludedFromRewardUpdated(account, false);
	}
	
	/**
	 * @notice Exclude an address from paying the transaction fee
	 * @param account address to be excluded from paying the transaction fee
	 */
	function excludeFromFee(address account) external onlyOwner() {
		_isExcludedFromFee[account] = true;
		emit AddressExcludedFromFeeUpdated(account, true);
	}
	
	/**
	 * @notice Include an address to pay the transaction fee
	 * @param account address to be included to pay the transaction fee
	 */
	function includeInFee(address account) external onlyOwner() {
		_isExcludedFromFee[account] = false;
		emit AddressExcludedFromFeeUpdated(account, false);
	}
	
	/**
	 * @notice Set the percentage of the net transaction value to be used to redistribute to token holders
	 * @param taxFee new percentage of the net transaction value to be used to redistribute to token holders
	 */
	function setTaxFeePercent(uint256 taxFee) external onlyOwner() {
		_taxFee = taxFee;
		emit TransactionFeeUpdated(taxFee);
	}
	
	/**
	 * @notice Set the percentage of the net transaction value to be used to provide liquidity
	 * @param liquidityFee new percentage of the net transaction value to be used to provide liquidity
	 */
	function setLiquidityFeePercent(uint256 liquidityFee) external onlyOwner() {
		_liquidityFee = liquidityFee;
		emit LiquidityFeeUpdated(liquidityFee);
	}
   
	/**
	 * @notice Set the maximum transaction limit as a percentage of the total token supply
	 * @param maxTxPercent new transaction limit as a percentage of the total token supply
	 */
	function setMaxTxPercent(uint256 maxTxPercent) external onlyOwner() {
		_maxTxAmount = _tTotal.mul(maxTxPercent).div(
			10**2
		);
		emit MaxTxAmountUpdated(_maxTxAmount);
	}

	/**
	 * @notice Set the minimum number of tokens collected from transaction fees before we sent them to PancakeSwap to provide liquidity
	 * @param minTokensBeforeSwap new minimum number of tokens collected from transaction fees before we sent them to PancakeSwap to provide liquidity
	 */
	function setMinTokensBeforeSwap(uint256 minTokensBeforeSwap) external onlyOwner() {
		numTokensSellToAddToLiquidity = minTokensBeforeSwap;
		emit MinTokensBeforeSwapUpdated(numTokensSellToAddToLiquidity);
	}

	/**
	 * @notice Enable or disable the feature to sent collected tokens from transaction fee to swap to provide liquidity
	 * @param _enabled enable or disable the feature
	 */
	function setSwapAndLiquifyEnabled(bool _enabled) external onlyOwner() {
		swapAndLiquifyEnabled = _enabled;
		emit SwapAndLiquifyEnabledUpdated(_enabled);
	}

	/// Tokenomics Features

	/**
	 * @notice Redistribute tAmount of token to all holders via reflection as if it is collected via a transaction fee
	 * @param tAmount amount of token to be redistributed
	 */
	function redistribute(uint256 tAmount) public {
		address sender = _msgSender();
		/// Since token balance of excluded address is defined by _tOwned instead of _rOwned,
		/// their token balance cannot be redistributed
		require(!_isExcluded[sender], "Excluded addresses cannot call this function");
		/// The equivalent amount of reflection that correspond to tAmount of token
		(uint256 rAmount,,,,,) = _getValues(tAmount);
		/// Subtract the amount of reflection (and therefore tAmount of token) from caller
		_rOwned[sender] = _rOwned[sender].sub(rAmount);
		/// Decrease total amount of reflection and increment the _tFeeTotal variable
		_rTotal = _rTotal.sub(rAmount);
		_tFeeTotal = _tFeeTotal.add(tAmount);
	}

	/**
	 * @notice Convert tAmount of token to an equivalent amount of the corresponding reflection, before or after fee
	 * @param tAmount amount of token
	 * @param deductTransferFee whether to deduct transaction fee or not
	 * @return uint256 amount of equivalent reflection
	 */
	function reflectionFromToken(uint256 tAmount, bool deductTransferFee) public view returns(uint256) {
		/// Check that tAmount is less than total token supply
		require(tAmount <= _tTotal, "Amount must be less than supply");
		if (!deductTransferFee) {
			/// Get the equivalent amount of reflection that corresponds to tAmount of token before fee
			(uint256 rAmount,,,,,) = _getValues(tAmount);
			return rAmount;
		} else {
			/// Get the equivalent amount of reflection that corresponds to tAmount of token after all transaction fee
			(,uint256 rTransferAmount,,,,) = _getValues(tAmount);
			return rTransferAmount;
		}
	}

	/**
	 * @notice Convert amount of reflection to amount of token
	 * @param rAmount amount of reflection
	 * @return uint256 equivalent amount of token
	 */
	function tokenFromReflection(uint256 rAmount) public view returns(uint256) {
		/// Check that rAmount is less than the total supply of reflection
		require(rAmount <= _rTotal, "Amount must be less than total reflections");
		/// Get the conversion rate between reflection and token
		uint256 currentRate =  _getRate();
		/// Actual token = amount of reflection / conversion rate
		return rAmount.div(currentRate);
	}

	/**
	 * @notice Reflect fee collected from a transaction in the total amount of reflection and the total fee variable
	 * @param rFee transaction fee collected in the unit of reflection
	 * @param tFee transaction fee collected in the unit of the actual token
	 */
	function _reflectFee(uint256 rFee, uint256 tFee) private {
		/// Subtract reflection destroyed due to transaction fee from total reflection supply
		_rTotal = _rTotal.sub(rFee);
		/// Increment total fee variable
		_tFeeTotal = _tFeeTotal.add(tFee);
	}

	/**
	 * @notice Get transaction parameter if tAmount of tokens is transferred
	 * @param tAmount amount of tokens to be transferred
	 * @return (
	 *		uint256 - the amount of reflection to be transferred or subtracted from the sender, 
	 *		uint256 - the amount of reflection to be rewarded to the recipient (with fee subtracted), 
	 *		uint256 - the amount of reflection to be collected as transaction tax for redistributing to token holders, 
	 *		uint256 - the amount of actual token to be rewarded to the recipient (with fee subtracted), 
	 *		uint256 - the amount of actual token to be collected as transaction tax for redistributing to token holders,
	 *		uint256 - the amount of actual token to be collected as transaction tax for providing liquidity
	 * )
	 */
	function _getValues(uint256 tAmount) private view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
		/// Get amount of token to be collected as fee and rewarded to recipient if tAmount of token was sent
		/// tAmount = tTransferAmount - tFee - tLiquidity
		(uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getTValues(tAmount);
		/// Get equivalent amount of reflection to be sent, received and collected as fee
		/// rAmount = rTransferAmount - rFee - tLiquidity * _getRate()
		(uint256 rAmount, uint256 rTransferAmount, uint256 rFee) = _getRValues(tAmount, tFee, tLiquidity, _getRate());
		return (rAmount, rTransferAmount, rFee, tTransferAmount, tFee, tLiquidity);
	}

	/**
	 * @notice Get transaction parameter if tAmount of tokens is transferred
	 * @param tAmount amount of tokens to be transferred
	 * @return (
	 *		uint256 - the amount of actual token to be rewarded to the recipient (with fee subtracted), 
	 *		uint256 - the amount of actual token to be collected as transaction tax for redistributing to token holders,
	 *		uint256 - the amount of actual token to be collected as transaction tax for providing liquidity
	 * )
	 */
	function _getTValues(uint256 tAmount) private view returns (uint256, uint256, uint256) {
		/// Calculate the amount of token to be collected as transaction tax for redistributing to token holders
		uint256 tFee = calculateTaxFee(tAmount);
		/// Calculate the amount of token to be collected as transaction tax for providing liquidity
		uint256 tLiquidity = calculateLiquidityFee(tAmount);
		/// Actual amount of token rewarded to recipient should be tAmount - tFee - tLiquidity
		uint256 tTransferAmount = tAmount.sub(tFee).sub(tLiquidity);
		return (tTransferAmount, tFee, tLiquidity);
	}

	/**
	 * @notice Get transaction parameter if tAmount of tokens is transferred
	 * @param tAmount amount of tokens to be transferred
	 * @param tFee amount of actual tokens to be collected as transaction tax for redistributing to token holders
	 * @param tLiquidity amount of actual tokens to be collected as transaction tax for providing liquidity
	 * @param currentRate current conversion ratio between reflection and the actual tokens
	 * @return (
	 *		uint256 - the amount of reflection to be transferred or subtracted from the sender, 
	 *		uint256 - the amount of reflection to be rewarded to the recipient (with fee subtracted), 
	 *		uint256 - the amount of reflection to be collected as transaction tax for redistributing to token holders where rAmount = rTransferAmount + rFee
	 * )
	 */
	function _getRValues(uint256 tAmount, uint256 tFee, uint256 tLiquidity, uint256 currentRate) private pure returns (uint256, uint256, uint256) {
		/// Amount of reflection to be subtracted from sender should be tAmount * currentRate
		uint256 rAmount = tAmount.mul(currentRate);
		/// Amount of reflection to be collected as transaction tax for redistribution should be tFee * currentRate
		uint256 rFee = tFee.mul(currentRate);
		/// Amount of reflection to be collected as transaction tax for providing liquidity should be tLiquidity * currentRate
		uint256 rLiquidity = tLiquidity.mul(currentRate);
		/// Actual amount of token to be rewarded to recipient should be rAmount - rFee - rLiquidity
		uint256 rTransferAmount = rAmount.sub(rFee).sub(rLiquidity);
		return (rAmount, rTransferAmount, rFee);
	}

	/**
	 * @notice Get the conversion rate between reflection and token
	 * @return uint256 conversion rate between reflection and token
	 */
	function _getRate() private view returns(uint256) {
		/// Get current total supply of reflection and token
		(uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
		/// Conversion rate is derived by total supply of reflection / total supply of token
		return rSupply.div(tSupply);
	}

	/**
	 * @notice Get the current supply of reflection and token
	 * @notice Note that reflection and token owned by an excluded address are excluded from the current supply
	 * @return (uint256 - current supply of reflection, uint256 - current token supply)
	 */
	function _getCurrentSupply() private view returns(uint256, uint256) {
		/// Default reflection supply and token supply should be its current total supply
		uint256 rSupply = _rTotal;
		uint256 tSupply = _tTotal;      
		/// Exclude excluded address from current supply
		for (uint256 i = 0; i < _excluded.length; i++) {
			/// This statement should never run since this will implies some address owns more than the total supply
			if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) return (_rTotal, _tTotal);
			/// Subtract reflection and token supply owned by the excluded address
			rSupply = rSupply.sub(_rOwned[_excluded[i]]);
			tSupply = tSupply.sub(_tOwned[_excluded[i]]);
		}
		/// This statement should never run unless almost all token supply is excluded
		if (rSupply < _rTotal.div(_tTotal)) return (_rTotal, _tTotal);
		/// Return the reflection and token supply with those owned by excluded address excluded
		return (rSupply, tSupply);
	}
	
	/**
	 * @notice Collect tLiquidity amount of token as transaction tax for providing liquidity to swap
	 * @param tLiquidity amount of token collected as transaction tax for providing liquidity to swap
	 */
	function _takeLiquidity(uint256 tLiquidity) private {
		/// Get current conversion ratio between reflection and token
		uint256 currentRate =  _getRate();
		/// Compute the equivalent amount of reflection that corresponds to tLiquidity amount of token
		uint256 rLiquidity = tLiquidity.mul(currentRate);
		/// Add the amount of reflection to this contract address
		/// Collected transaction tax will be automatically send to swap to provide liquidity 
		/// once it collects more than numTokensSellToAddToLiquidity of token in the next transaction
		/// Note that we don't have to subtract any reflection here, since it is already handled by the 
		/// transfer function
		_rOwned[address(this)] = _rOwned[address(this)].add(rLiquidity);
		if(_isExcluded[address(this)])
			/// If this contract is an excluded address, then we have to add the token collected to _tOwned as well
			_tOwned[address(this)] = _tOwned[address(this)].add(tLiquidity);
	}
	
	/**
	 * @notice Calculate the amount of token to be collected as a transaction fee for redistribution
	 * @param _amount amount of token transferred
	 * @return uint256 amount of token to be collected as a transaction fee for redistribution for this transaction
	 */
	function calculateTaxFee(uint256 _amount) private view returns (uint256) {
		/// _taxFee represent the percentage of net transaction value to be collected
		return _amount.mul(_taxFee).div(
			10**2
		);
	}

	/**
	 * @notice Calculate the amount of token to be collected as a transaction fee for providing liquidity
	 * @param _amount amount of token transferred
	 * @return uint256 amount of token to be collected as a transaction fee for providing liquidity for this transaction
	 */
	function calculateLiquidityFee(uint256 _amount) private view returns (uint256) {
		/// _liquidityFee represent the percentage of net transaction value to be collected
		return _amount.mul(_liquidityFee).div(
			10**2
		);
	}
	
	/**
	 * @notice Temporarily disable transaction fee in _tokenTransfer for address in _isExcludedFromFee mapping
	 */
	function removeAllFee() private {
		/// No need to set _taxFee and _liquidityFee if it is already 0
		if(_taxFee == 0 && _liquidityFee == 0) return;
		/// Store the original _taxFee and _liquidityFee
		_previousTaxFee = _taxFee;
		_previousLiquidityFee = _liquidityFee;
		/// Set both fee to 0
		_taxFee = 0;
		_liquidityFee = 0;
	}
	
	/**
	 * @notice Revert removeAllFee() after transaction is over
	 */
	function restoreAllFee() private {
		/// Restore _taxFee and _liquidityFee
		_taxFee = _previousTaxFee;
		_liquidityFee = _previousLiquidityFee;
	}
	
	/**
	 * @notice Check whether an address is excluded from the transaction fee
	 * @param account address to be checked
	 * @return bool whether the address is excluded from transaction fee
	 */
	function isExcludedFromFee(address account) public view returns(bool) {
		return _isExcludedFromFee[account];
	}

	/**
	 * @notice Set allowance that spender can spend on behalf of the owner
	 * @param owner address that authorizes spender to spend on its behalf
	 * @param spender address that is authorized to spend owner's token
	 * @param amount amount of token the spender is authorized to spend
	 */
	function _approve(address owner, address spender, uint256 amount) private {
		/// Make sure owner and spender is not 0 address and set the allowance
		/// The use of reflection does not affect the allowance mechanics
		require(owner != address(0), "ERC20: approve from the zero address");
		require(spender != address(0), "ERC20: approve to the zero address");
		_allowances[owner][spender] = amount;
		emit Approval(owner, spender, amount);
	}

	/**
	 * @notice Transfer 'amount' of token from 'from' to 'to'
	 * @param from the sender address
	 * @param to the recipient address
	 * @param amount amount of token sent out from sender address, note that recipient will receive less token
	 */
	function _transfer(address from, address to, uint256 amount) private {
		/// Require non-zero address and non-zero amount to be transferred
		require(from != address(0), "ERC20: transfer from the zero address");
		require(to != address(0), "ERC20: transfer to the zero address");
		require(amount > 0, "Transfer amount must be greater than zero");
		/// Require amount of token transferred to be under the _maxTxAmount limit
		if (from != owner() && to != owner()) {
			require(amount <= _maxTxAmount, "Transfer amount exceeds the maxTxAmount.");
		}
		/// Get the amount of token collected from transaction fee and is now owned by this contract
		uint256 contractTokenBalance = balanceOf(address(this));
		/// Since this contract cannot transfer more than _maxTxAmount at once either,
		/// set the contractTokenBalance to _maxTxAmount if it exceeds it
		if (contractTokenBalance >= _maxTxAmount) {
			contractTokenBalance = _maxTxAmount;
		}
		/// Check if contractTokenBalance exceeds the minimum required to provide liquidity to swap
		bool overMinTokenBalance = contractTokenBalance >= numTokensSellToAddToLiquidity;
		/// Initiate to provide liquidity if,
		/// 1. contractTokenBalance exceeds the minimum required to provide liquidity to swap
		/// 2. We are not already providing liquidity as indicated by the inSwapAndLiquify (i.e. it should be false)
		/// 3. Sender is not a pancakeswap pair otherwise it may affect the swap itself
		/// 4. Contract is set to provide liquidity via the swapAndLiquifyEnabled flag
		if (
			overMinTokenBalance &&
			!inSwapAndLiquify &&
			from != pancakeSwapProxy.pancakeswapV2Pair() &&
			swapAndLiquifyEnabled
		) {
			/// We will provide numTokensSellToAddToLiquidity amount of token for liquidity
			contractTokenBalance = numTokensSellToAddToLiquidity;
			/// Add liquidity to swap
			swapAndLiquify(contractTokenBalance);
		}
		/// Boolean that indicates if fee should be deducted from transfer
		bool takeFee = true;
		// If any account belongs to _isExcludedFromFee account then remove the fee
		if(_isExcludedFromFee[from] || _isExcludedFromFee[to]){
			takeFee = false;
		}
		/// Transfer amount of token, it will take transaction fee if takeFee is true
		_tokenTransfer(from, to, amount, takeFee);
	}

	/**
	 * @notice Swap token into BUSD and provide liquidity to Pancakeswap
	 * @param contractTokenBalance amount of token to be swap and provide liquidity
	 */
	function swapAndLiquify(uint256 contractTokenBalance) private lockTheSwap {
		/// Transfer the TDM token to be swapped and liquify into PancakeSwapProxy without fee
		_tokenTransfer(address(this), address(pancakeSwapProxy), contractTokenBalance, false);
		/// Call PancakeSwapProxy to swap and liquify for us
		(uint256 half, uint256 busdSwapped, uint256 otherHalf) = pancakeSwapProxy.swapAndLiquify();
		/// Emit event
		emit SwapAndLiquify(half, busdSwapped, otherHalf);
	}

	/**
	 * @notice Process the transaction and take transaction fee if takeFee is true
	 * @param sender transaction sender
	 * @param recipient transaction recipient
	 * @param amount amount of token transferred
	 * @param takeFee whether to take transaction fee or not
	 */
	function _tokenTransfer(address sender, address recipient, uint256 amount, bool takeFee) private {
		/// Exclude fee if takeFee is false
		if (!takeFee) {
			removeAllFee();
		}
		/// Process transaction depending on whether sender/receipient is an excluded address or not
		if (_isExcluded[sender] && !_isExcluded[recipient]) {
			_transferFromExcluded(sender, recipient, amount);
		} 
		else if (!_isExcluded[sender] && _isExcluded[recipient]) {
			_transferToExcluded(sender, recipient, amount);
		} 
		else if (_isExcluded[sender] && _isExcluded[recipient]) {
			_transferBothExcluded(sender, recipient, amount);
		} 
		else {
			_transferStandard(sender, recipient, amount);
		}
		/// Restore fee if takeFee is false after transaction
		if (!takeFee) {
			restoreAllFee();
		}
	}

	/**
	 * @notice Handle token transfer between non-excluded addresses.
	 * @param sender transaction sender
	 * @param recipient transaction recipient
	 * @param tAmount amount of token transferred
	 */
	function _transferStandard(address sender, address recipient, uint256 tAmount) private {
		/// Get transaction parameters
		(uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getValues(tAmount);
		/// For non-excluded addresses, it is only necessary to transfer the reflection from sender to recipient
		_rOwned[sender] = _rOwned[sender].sub(rAmount);
		_rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
		/// Take liquidity from the transaction by reserving tLiquidity amount of token to this contract
		_takeLiquidity(tLiquidity);
		/// Record the amount of reflection burned and amount of token redistributed to all token holders
		_reflectFee(rFee, tFee);
		/// Emit transfer event
		emit Transfer(sender, recipient, tTransferAmount);
	}

	/**
	 * @notice Handle token transfer from a non-excluded address to an excluded address.
	 * @param sender transaction sender
	 * @param recipient transaction recipient
	 * @param tAmount amount of token transferred
	 */
	function _transferToExcluded(address sender, address recipient, uint256 tAmount) private {
		/// Get transaction parameters
		(uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getValues(tAmount);
		/// For non-excluded sender, it is only necessary to subtract equivalent amount of reflection
		_rOwned[sender] = _rOwned[sender].sub(rAmount);
		/// For excluded recipient, it is necessary to add both reflection in _rOwned and actual token counter in _tOwned
		_tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
		_rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);           
		/// Take liquidity from the transaction by reserving tLiquidity amount of token to this contract
		_takeLiquidity(tLiquidity);
		/// Record the amount of reflection burned and amount of token redistributed to all token holders
		_reflectFee(rFee, tFee);
		/// Emit transfer event
		emit Transfer(sender, recipient, tTransferAmount);
	}

	/**
	 * @notice Handle token transfer from an excluded address to a non-excluded address.
	 * @param sender transaction sender
	 * @param recipient transaction recipient
	 * @param tAmount amount of token transferred
	 */
	function _transferFromExcluded(address sender, address recipient, uint256 tAmount) private {
		/// Get transaction parameters
		(uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getValues(tAmount);
		/// For excluded recipient, it is necessary to subtract both reflection in _rOwned and actual token counter in _tOwned
		_tOwned[sender] = _tOwned[sender].sub(tAmount);
		_rOwned[sender] = _rOwned[sender].sub(rAmount);
		/// For non-excluded sender, it is only necessary to add the corresponding amount of reflection
		_rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);   
		/// Take liquidity from the transaction by reserving tLiquidity amount of token to this contract
		_takeLiquidity(tLiquidity);
		/// Record the amount of reflection burned and amount of token redistributed to all token holders
		_reflectFee(rFee, tFee);
		/// Emit transfer event
		emit Transfer(sender, recipient, tTransferAmount);
	}

	/**
	 * @notice Handle token transfer between excluded addresses.
	 * @param sender transaction sender
	 * @param recipient transaction recipient
	 * @param tAmount amount of token transferred
	 */
	function _transferBothExcluded(address sender, address recipient, uint256 tAmount) private {
		/// Get transaction parameters
		(uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getValues(tAmount);
		/// For excluded addresses, it is necessary to transfer both the reflection in _rOwned and actual token count in _tOwned from sender to recipient
		_tOwned[sender] = _tOwned[sender].sub(tAmount);
		_rOwned[sender] = _rOwned[sender].sub(rAmount);
		_tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
		_rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);      
		/// Take liquidity from the transaction by reserving tLiquidity amount of token to this contract
		_takeLiquidity(tLiquidity);
		/// Record the amount of reflection burned and amount of token redistributed to all token holders
		_reflectFee(rFee, tFee);
		/// Emit transfer event
		emit Transfer(sender, recipient, tTransferAmount);
	}

}