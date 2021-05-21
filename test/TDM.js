const fs = require("fs");
const { expect } = require("chai");
const { ethers } = require("hardhat");

// Utility Methods

// Constant
const BUSDTokenContractAddress = "0xe9e7cea3dedca5984780bafc599bd69add087d56";
const PancakeswapRouterAddress = "0x10ED43C718714eb63d5aA57B78B54704E256024E";

/**
 * Convert amount of USD into BUSD's 18 decimals representation.
 * @param {*} amountInUSD amount of USD to be converted
 * @returns equivalent amount of BUSD with 18 decimals places
 */
function toBUSD(amountInUSD) {
	return amountInUSD + "000000000000000000";
}

/**
 * Convert an existing TDM contract instance into another signer.
 * @param {*} TDMContractInstance existing TDM contract instance
 * @param {*} signer new signer
 * @returns new TDM contract instance but with a new signer
 */
function getTDMContract(TDMContractInstance, signer) {
	return new ethers.Contract(TDMContractInstance.address, TDMContractInstance.interface, signer);
}

/**
 * Get a new BUSD contract instance using signer's perspective.
 * @param {*} signer signer instance
 * @returns BUSD contract instance
 */
function getBUSDContract(signer) {
	return new ethers.Contract(BUSDTokenContractAddress, JSON.parse(fs.readFileSync("./test/BUSD_ABI.json")), signer);
}

/**
 * Get a new PancakeswapRouter contract instance using signer's perspective.
 * @param {*} signer signer instance
 * @returns PancakeswapRouter contract instance
 */
function getPancakeswapRouterContract(signer) {
	return new ethers.Contract(PancakeswapRouterAddress, JSON.parse(fs.readFileSync("./test/PancakeSwapRouter_ABI.json")), signer);
}

/**
 * Impersonate BUSD owner address to mint and send 100,000 BUSD to all signers
 */
async function getBUSDToSigners() {
	// Get list of signers 
	const signers = await ethers.getSigners();
	// Get the BUSD owner address
	const BUSD = getBUSDContract(signers[0]);
	const BUSDOwner = await BUSD.getOwner();
	// Impersonate BUSD owner address
	await hre.network.provider.request({
		method: "hardhat_impersonateAccount",
		params: [BUSDOwner]} // Owner of BUSD contract
	);
	const BUSDOwnerSigner = await ethers.provider.getSigner(BUSDOwner);
	const BUSDWithOwnerPermission = getBUSDContract(BUSDOwnerSigner);
	// Mint 100,000 BUSD for each signer
	await BUSDWithOwnerPermission.mint(toBUSD(100000 * signers.length));
	// Transfer 100,000 BUSD to each signer
	for (let i=0; i<signers.length; i++) {
		await BUSDWithOwnerPermission.transfer(signers[i].address, toBUSD(100000));
	}
	// Stop impersonation
	await hre.network.provider.request({
		method: "hardhat_stopImpersonatingAccount",
		params: [BUSDOwner]}
	);
}

/**
 * Get the token balance of an account after a transaction.
 * @param {*} reflectionOwnedAfterTransaction amount of reflection owned by an address after transaction
 * @param {*} initialTotalReflection initial total supply of reflection
 * @param {*} reflectionRedistributed equivalent amount of reflection that corresponds to the amount of token redistributed
 * @param {*} tokenTotalSupply total supply of TDM token
 * @returns amount of TDM token after the transaction
 */
function getTokenBalanceAfterTransaction(reflectionOwnedAfterTransaction, initialTotalReflection, reflectionRedistributed, tokenTotalSupply) {
	return (reflectionOwnedAfterTransaction.mul(tokenTotalSupply).div(initialTotalReflection.sub(reflectionRedistributed)));
}

/**
 * Obtain the TDM and BUSD reserves stored in the LP token contract.
 * @param {*} lpTokenContract LP token contract instance
 * @returns An array where first element represent the amount of TDM in reserve, and second element represent the amount of BUSD in reserve
 */
async function getReserves(lpTokenContract) {
	// Get reserves in the LP token contract
	const reserves = await lpTokenContract.getReserves();
	// For some reason, getReserves will occasionally return the amount of BUSD in reserve first, instead of TDM which is expected in the tests
	// Check if reserves[0] > reserves[1]
	if (reserves[0].gt(reserves[1])) {
		// Assuming TDM in reserve is always lower than BUSD in reserve, if reserves[0] > reserves[1], 
		// then reserves[0] represent the BUSD balance, and reserves[1] represent TDM balance
		// This assumption is usually true since TDM uses 6 decimals while BUSD uses 18 decimals
		return [ reserves[1], reserves[0] ];
	}
	else {
		return [ reserves[0], reserves[1] ];
	}
}

describe("TODAMOON Token Contract", function() {

	// TDMToken contract instance from the perspective of the owner
	let TDMToken;
	
	before(async function() {
		// Mint and send 100,000 BUSD to signers
		await getBUSDToSigners();
	});

	// Deployment Tests
	describe("TODAMOON Deployment", function() {

		beforeEach(async function() {
			// Deploy TDM
			const TDMTokenContract = await ethers.getContractFactory("TODAMOON");
			TDMToken = await TDMTokenContract.deploy();
		});

		it("Basic token information should be correct", async function() {
			expect(await TDMToken.name()).to.equal("TODAMOON");
			expect(await TDMToken.symbol()).to.equal("TDM");
			expect(await TDMToken.decimals()).to.equal(6);
		});
	
		it("Deployment should assign the total supply of tokens to the owner", async function() {
			const [owner] = await ethers.getSigners();
			const ownerBalance = await TDMToken.balanceOf(owner.address);
			expect(await TDMToken.totalSupply()).to.equal(ownerBalance);
		});
	
		it("Sending 60% of total supply to address(1) should work", async function() {
			const totalSupply = await TDMToken.totalSupply();
			const burnerAddress = "0x0000000000000000000000000000000000000001";
			await TDMToken.transfer(burnerAddress, totalSupply.mul(60).div(100));
			expect(await TDMToken.balanceOf(burnerAddress)).to.equal(totalSupply.mul(60).div(100));
		});
	
		it("Supplying 35% of total supply with 7,000 BUSD to PancakeSwap should work", async function() {
			const [owner] = await ethers.getSigners();
			const totalSupply = await TDMToken.totalSupply();
			const pancakeswapRouter = getPancakeswapRouterContract(owner);
			const BUSD = getBUSDContract(owner);
			await TDMToken.approve(PancakeswapRouterAddress, totalSupply.mul(35).div(100));
			await BUSD.approve(PancakeswapRouterAddress, toBUSD(7000));
			await pancakeswapRouter.addLiquidity(
				TDMToken.address, 
				BUSDTokenContractAddress,
				totalSupply.mul(35).div(100),
				toBUSD(7000),
				0,
				0,
				owner.address,
				Date.now()+100000
			);
			const pancakeSwapProxyAddress = await TDMToken.pancakeSwapProxy();
			const pancakeSwapProxy = await ethers.getContractAt("PancakeSwapProxy", pancakeSwapProxyAddress, owner);
			const lpTokenAddress = await pancakeSwapProxy.pancakeswapV2Pair();
			const lpTokenContract = new ethers.Contract(lpTokenAddress, JSON.parse(fs.readFileSync("./test/PancakePair_ABI.json")), owner);
			const lpTokenReserves = await getReserves(lpTokenContract);
			expect(lpTokenReserves[0]).to.equal(totalSupply.mul(35).div(100)); // Expect 35% of TDM total supply to be in the pool
			expect(lpTokenReserves[1]).to.equal(toBUSD(7000)); // Expect 10,000 BUSD to be in the pool
		});
	
		it("TODAMOON token should be purchasable from the swap after initial liquidity is supplied", async function() {
			// Providing liquidity
			const [owner, purchaser] = await ethers.getSigners();
			const totalSupply = await TDMToken.totalSupply();
			const pancakeswapRouter = getPancakeswapRouterContract(owner);
			const BUSD = getBUSDContract(owner);
			await TDMToken.approve(PancakeswapRouterAddress, totalSupply.mul(35).div(100));
			await BUSD.approve(PancakeswapRouterAddress, toBUSD(7000));
			await pancakeswapRouter.addLiquidity(
				TDMToken.address, 
				BUSDTokenContractAddress,
				totalSupply.mul(35).div(100),
				toBUSD(7000),
				0,
				0,
				owner.address,
				Date.now()+100000
			);
			// Purchase with another account
			const pancakeswapRouterPurchaser = getPancakeswapRouterContract(purchaser);
			const BUSDPurchaser = getBUSDContract(purchaser);
			await BUSDPurchaser.approve(PancakeswapRouterAddress, toBUSD(500));
			await pancakeswapRouterPurchaser.swapExactTokensForTokensSupportingFeeOnTransferTokens(
				toBUSD(500),
				0,
				[ BUSDPurchaser.address, TDMToken.address ],
				purchaser.address,
				Date.now()+100000
			);
			const purchaserTokenBalance = await TDMToken.balanceOf(purchaser.address);
			expect(purchaserTokenBalance.gt(0)); // Non-zero balance which indicate the purchase has succeed
		});

	});

	// Token Mechanics Tests 
	describe("TODAMOON Token Mechanics", async function() {

		beforeEach(async function() {
			// Deploy TDM
			const TDMTokenContract = await ethers.getContractFactory("TODAMOON");
			TDMToken = await TDMTokenContract.deploy();
		});

		it("Able to increase and decrease allowance", async function() {
			const [owner, spender] = await ethers.getSigners();
			expect(await TDMToken.allowance(owner.address, spender.address)).to.equal(0); // Allowance should be 0 by default
			await TDMToken.increaseAllowance(spender.address, 100); // Raise allowance to 100
			expect(await TDMToken.allowance(owner.address, spender.address)).to.equal(100); // Allowance should now be 100
			await TDMToken.decreaseAllowance(spender.address, 50); // Decrease allowance by 50
			expect(await TDMToken.allowance(owner.address, spender.address)).to.equal(50); // Allowance should now be 100
		});

		it("Able to include and exclude an account from fee", async function() {
			const [owner, notOwner] = await ethers.getSigners();
			expect(await TDMToken.isExcludedFromFee(owner.address)).to.be.true; // Owner is by default excluded from fee
			expect(await TDMToken.isExcludedFromFee(notOwner.address)).to.be.false; // Other addreses are by default included in fee scheme
			await TDMToken.includeInFee(owner.address); // Include owner in fee scheme
			expect(await TDMToken.isExcludedFromFee(owner.address)).to.be.false;
			await TDMToken.excludeFromFee(owner.address); // Exclude owner from fee again
			expect(await TDMToken.isExcludedFromFee(owner.address)).to.be.true;
			// Test whether these functions reverts as expected when called by non-owner
			const TDMTokenNonOwner = getTDMContract(TDMToken, notOwner);
			await expect(TDMTokenNonOwner.includeInFee(owner.address)).to.be.revertedWith("Ownable: caller is not the owner"); // Should revert
			await expect(TDMTokenNonOwner.excludeFromFee(owner.address)).to.be.revertedWith("Ownable: caller is not the owner"); // Should revert
		});

		it("Able to include and exclude an account from reflection reward", async function() {
			const [owner, notOwner] = await ethers.getSigners();
			expect(await TDMToken.isExcludedFromReward(owner.address)).to.be.false; // No address is by default excluded from reflection reward
			expect(await TDMToken.isExcludedFromReward(notOwner.address)).to.be.false; // No address is by default excluded from reflection reward
			const ownerBalanceOriginal = await TDMToken.balanceOf(owner.address); // Get owner balance before any operation
			const notOwnerBalanceOriginal = await TDMToken.balanceOf(notOwner.address); // Get notOwner balance before any operation
			await TDMToken.excludeFromReward(owner.address); // Exclude owner from reflection reward
			await TDMToken.excludeFromReward(notOwner.address); // Exclude notOwner from reflection reward
			expect(await TDMToken.isExcludedFromReward(owner.address)).to.be.true;
			expect(await TDMToken.isExcludedFromReward(notOwner.address)).to.be.true;
			expect(await TDMToken.balanceOf(owner.address)).to.equal(ownerBalanceOriginal); // Exclusion from reflection reward should not change its balance
			expect(await TDMToken.balanceOf(notOwner.address)).to.equal(notOwnerBalanceOriginal); // Exclusion from reflection reward should not change its balance
			await TDMToken.includeInReward(owner.address); // Include owner in reflection reward
			await TDMToken.includeInReward(notOwner.address); // Include notOwner in reflection reward
			expect(await TDMToken.isExcludedFromReward(owner.address)).to.be.false;
			expect(await TDMToken.isExcludedFromReward(notOwner.address)).to.be.false;
			expect(await TDMToken.balanceOf(owner.address)).to.equal(ownerBalanceOriginal); // Inclusion in reflection reward should not change its balance
			expect(await TDMToken.balanceOf(notOwner.address)).to.equal(notOwnerBalanceOriginal); // Inclusion in reflection reward should not change its balance
			// Test whether these functions reverts as expected when called by non-owner
			const TDMTokenNonOwner = getTDMContract(TDMToken, notOwner);
			await expect(TDMTokenNonOwner.excludeFromReward(owner.address)).to.be.revertedWith("Ownable: caller is not the owner"); // Should revert
			await expect(TDMTokenNonOwner.includeInReward(owner.address)).to.be.revertedWith("Ownable: caller is not the owner"); // Should revert
		});

		it("Address excluded from reflection reward can transfer and receive token as expected", async function() {
			const [owner, notOwner] = await ethers.getSigners(); // Transferring to/from owner always incurs no transaction fee
			let ownerBalanceOriginal = await TDMToken.balanceOf(owner.address);
			let notOwnerBalanceOriginal = await TDMToken.balanceOf(notOwner.address);
			// Get initial total token supply
			const totalSupply = await TDMToken.totalSupply();
			/// Transfer from excluded address to normal address
			let transferAmount = totalSupply.mul(1).div(100); // 1% of total supply to be transferred
			let receiveAmount = await TDMToken.reflectionFromToken(transferAmount, false); // Predict the amount of reflection to be received before fee
			await TDMToken.excludeFromReward(owner.address); // Exclude owner from reflection reward
			await TDMToken.transfer(notOwner.address, transferAmount); // Transfer 1% TDM from excluded address to included address
			expect(await TDMToken.balanceOf(owner.address)).to.equal(ownerBalanceOriginal.sub(transferAmount)); // Expect amount of token transferred to be subtracted from sender's address
			expect(await TDMToken.balanceOf(notOwner.address)).to.equal(notOwnerBalanceOriginal.add(await TDMToken.tokenFromReflection(receiveAmount))); // Expect the amount of token received to be correct
			/// Transfer from normal address to excluded address
			const TDMTokenNotOwner = getTDMContract(TDMToken, notOwner);
			ownerBalanceOriginal = await TDMToken.balanceOf(owner.address); // Get updated balance of the owner
			notOwnerBalanceOriginal = await TDMToken.balanceOf(notOwner.address); // Get updated balance of the notOwner
			transferAmount = await TDMTokenNotOwner.balanceOf(notOwner.address); // Transfer entire balance of notOwner to owner
			receiveAmount = await TDMTokenNotOwner.reflectionFromToken(transferAmount, false); // Predict the amount of reflection to be received before fee
			await TDMTokenNotOwner.transfer(owner.address, transferAmount);
			expect(await TDMTokenNotOwner.balanceOf(notOwner.address)).to.equal(notOwnerBalanceOriginal.sub(transferAmount)); // Expect amount of token transferred to be subtracted from sender's address
			expect(await TDMTokenNotOwner.balanceOf(owner.address)).to.equal(ownerBalanceOriginal.add(await TDMTokenNotOwner.tokenFromReflection(receiveAmount))); // Expect the amount of token received to be correct
			/// Transfer between excluded addresses
			ownerBalanceOriginal = await TDMToken.balanceOf(owner.address); // Get updated balance of the owner
			notOwnerBalanceOriginal = await TDMToken.balanceOf(notOwner.address); // Get updated balance of the notOwner
			transferAmount = totalSupply.mul(1).div(100); // 1% of total supply to be transferred
			receiveAmount = await TDMToken.reflectionFromToken(transferAmount, false); // Predict the amount of reflection to be received before fee
			await TDMToken.excludeFromReward(notOwner.address); // Exclude notOwner from reflection reward
			await TDMToken.transfer(notOwner.address, transferAmount); // Transfer 1% TDM between excluded address
			expect(await TDMToken.balanceOf(owner.address)).to.equal(ownerBalanceOriginal.sub(transferAmount)); // Expect amount of token transferred to be subtracted from sender's address
			expect(await TDMToken.balanceOf(notOwner.address)).to.equal(notOwnerBalanceOriginal.add(await TDMToken.tokenFromReflection(receiveAmount))); // Expect the amount of token received to be correct
		});

		it("Able to set percentage of transaction value used for redistribution to token holders and providing liquidity to the swap", async function() {
			const [_, notOwner] = await ethers.getSigners();
			// Setting percentage of transaction value used for redistribution to token holders
			const originalTaxFee = await TDMToken._taxFee();
			await TDMToken.setTaxFeePercent(originalTaxFee.add(1)); // Add 1% tax fee
			expect(await TDMToken._taxFee()).to.equal(originalTaxFee.add(1)); // Expect tax fee has raised by 1%
			// Setting percentage of transaction value used for providing liquidity
			const originalLiquidityFee = await TDMToken._liquidityFee();
			await TDMToken.setLiquidityFeePercent(originalLiquidityFee.add(1)); // Add 1% liquidity fee
			expect(await TDMToken._liquidityFee()).to.equal(originalLiquidityFee.add(1)); // Expect tax fee has raised by 1%
			// Test whether these functions reverts as expected when called by non-owner
			const TDMTokenNonOwner = getTDMContract(TDMToken, notOwner);
			await expect(TDMTokenNonOwner.setTaxFeePercent(originalTaxFee.add(1))).to.be.revertedWith("Ownable: caller is not the owner"); // Should revert
			await expect(TDMTokenNonOwner.setLiquidityFeePercent(originalLiquidityFee.add(1))).to.be.revertedWith("Ownable: caller is not the owner"); // Should revert
		});

		it("Able to set maximum transaction limit as percentage of total token supply", async function() {
			const [_, notOwner, notOwnerTwo] = await ethers.getSigners();
			const totalSupply = await TDMToken.totalSupply(); // Get initial total token supply
			await TDMToken.transfer(notOwner.address, totalSupply.mul(10).div(100)); // Transfer 10% of token supply to notOwner, owner is not bound by this limit
			await TDMToken.setMaxTxPercent(1); // Set maximum transaction limit to 1% of total supply
			expect(await TDMToken._maxTxAmount()).to.equal(totalSupply.mul(1).div(100)); // Expect limit to be 1% now
			const TDMTokenNotOwner = getTDMContract(TDMToken, notOwner);
			expect(await TDMTokenNotOwner.transfer(notOwnerTwo.address, totalSupply.mul(1).div(100))); // Should succeed
			await expect(TDMTokenNotOwner.transfer(notOwnerTwo.address, totalSupply.mul(1).div(100).add(1))).to.be.revertedWith("Transfer amount exceeds the maxTxAmount."); // Should revert
			// Test whether this function reverts as expected when called by non-owner
			await expect(TDMTokenNotOwner.setMaxTxPercent(1)).to.be.revertedWith("Ownable: caller is not the owner"); // Should revert
		});

		it("Able to set minimum number of tokens collected from transaction fee before we sent to swap to provide liquidity", async function() {
			const [_, notOwner] = await ethers.getSigners();
			const totalSupply = await TDMToken.totalSupply(); // Get initial total token supply
			// Setting the minimum to 1% of token supply and checking the MinTokensBeforeSwapUpdated event
			const newMinimum = totalSupply.mul(10).div(100);
			await expect(TDMToken.setMinTokensBeforeSwap(newMinimum))
				.to.emit(TDMToken, "MinTokensBeforeSwapUpdated")
				.withArgs(newMinimum);
			// Test whether this function reverts as expected when called by non-owner
			const TDMTokenNonOwner = getTDMContract(TDMToken, notOwner);
			await expect(TDMTokenNonOwner.setMinTokensBeforeSwap(newMinimum)).to.be.revertedWith("Ownable: caller is not the owner"); // Should revert
		});

		it("Able to enable and disable the swap and liquidify feature", async function() {
			const [_, notOwner] = await ethers.getSigners();
			await TDMToken.setSwapAndLiquifyEnabled(false); // Disable swap and liquidify feature
			expect(await TDMToken.swapAndLiquifyEnabled()).to.be.false;
			await TDMToken.setSwapAndLiquifyEnabled(true); // Enable swap and liquidify feature
			expect(await TDMToken.swapAndLiquifyEnabled()).to.be.true;
			// Test whether this function reverts as expected when called by non-owner
			const TDMTokenNonOwner = getTDMContract(TDMToken, notOwner);
			await expect(TDMTokenNonOwner.setSwapAndLiquifyEnabled(false)).to.be.revertedWith("Ownable: caller is not the owner"); // Should revert
			await expect(TDMTokenNonOwner.setSwapAndLiquifyEnabled(true)).to.be.revertedWith("Ownable: caller is not the owner"); // Should revert
		});

		it("Able to burn and redistribute token to all token holders", async function() {
			const [_, notOwner] = await ethers.getSigners();
			const totalSupply = await TDMToken.totalSupply(); // Get initial total token supply
			await TDMToken.transfer(notOwner.address, totalSupply.mul(1).div(100)); // Transfer 1% of token supply to notOwner
			await TDMToken.redistribute(totalSupply.mul(99).div(100)); // Burn and redistribute all token owned by the owner (i.e. 99% of token supply)
			expect(await TDMToken.balanceOf(notOwner.address)).to.equal(totalSupply); // notOwner should now own entire token supply
		});

	});

	// Tokenomics Tests
	describe("TODAMOON Tokenomics", function() {

		beforeEach(async function() {
			// Deploy TDM
			const TDMTokenContract = await ethers.getContractFactory("TODAMOON");
			TDMToken = await TDMTokenContract.deploy();
			// Provide 35% of total supply with 7,000 BUSD to Pancakeswap
			const signers = await ethers.getSigners();
			const totalSupply = await TDMToken.totalSupply();
			const pancakeswapRouter = getPancakeswapRouterContract(signers[0]);
			const BUSD = getBUSDContract(signers[0]);
			await TDMToken.approve(PancakeswapRouterAddress, totalSupply.mul(35).div(100));
			await BUSD.approve(PancakeswapRouterAddress, toBUSD(7000));
			await pancakeswapRouter.addLiquidity(
				TDMToken.address, 
				BUSDTokenContractAddress,
				totalSupply.mul(35).div(100),
				toBUSD(7000),
				0,
				0,
				signers[0].address,
				Date.now()+100000
			);
			// We are skipping to put 60% of token supply into address(1) for easier test condition
			// Sending 10% of supply to signer[1] - signers[5]
			// No need to test transfer from owner again, since this is already tested in 
			// "TODAMOON Deployment - Sending 60% of total supply to address(1) should work"
			for (let i=1; i<6; i++) {
				await TDMToken.transfer(signers[i].address, totalSupply.mul(10).div(100));
			}
		});

		it("Transferring between normal address should have 5% of net transaction value redistributed and 5% of net transaction value for providing liquidity", async function() {
			// Get initial total token and reflection supply, and compute their ratio
			const totalSupply = await TDMToken.totalSupply();
			const totalReflectionSupply = await TDMToken.reflectionFromToken(totalSupply, false);
			const reflectionToTokenConversionRate = totalReflectionSupply.div(totalSupply);
			// Transferring 1% of total supply from signers[1] to signers[11]
			const signers = await ethers.getSigners();
			const TDMTokenSignerOne = getTDMContract(TDMToken, signers[1]);
			const signerEleventReflectionOwnedAfterTx = await TDMToken.reflectionFromToken(totalSupply.mul(1).div(100), true); // Predicting the amount of reflection signers[11] will receive after the transaction using reflectionFromToken
			await TDMTokenSignerOne.transfer(signers[11].address, totalSupply.mul(1).div(100));
			// Check if totalFees is equivalent to the amount of token redistributed - i.e. 1% * 5% of total supply
			const totalFees = await TDMToken.totalFees();
			const expectedRedistributedToken = totalSupply.mul(1).div(100).mul(5).div(100); // This transaction should redistribute 1% * 5% of total supply
			expect(totalFees).to.equal(expectedRedistributedToken);
			// Get balance of signers[1], signers[11] and the contract address
			const balanceOfSignerOne = await TDMToken.balanceOf(signers[1].address);
			const balanceOfSignerEleven = await TDMToken.balanceOf(signers[11].address);
			const balanceOfContract = await TDMToken.balanceOf(TDMToken.address);
			// Check if balance are as expected
			// Balance after transaction can be derived by (Reflection owned after transfer) / (Total reflection - Equivalent amount of reflection as token redistributed)
			expect(balanceOfSignerOne).to.equal(
				getTokenBalanceAfterTransaction(
					totalSupply.mul(9).div(100).mul(reflectionToTokenConversionRate), // Signers[1] owns 9% of reflection supply after transfer
					totalReflectionSupply, 
					expectedRedistributedToken.mul(reflectionToTokenConversionRate), 
					totalSupply
				)
			);
			expect(signerEleventReflectionOwnedAfterTx).to.equal(totalSupply.mul(1).div(100).mul(90).div(100).mul(reflectionToTokenConversionRate)); // Signers[11] should own 1% * 90% of reflection supply after transfer (with 10% subtracted as fee)
			expect(balanceOfSignerEleven).to.equal(
				getTokenBalanceAfterTransaction(
					signerEleventReflectionOwnedAfterTx, 
					totalReflectionSupply, 
					expectedRedistributedToken.mul(reflectionToTokenConversionRate), 
					totalSupply
				)
			);
			expect(balanceOfContract).to.equal(
				getTokenBalanceAfterTransaction(
					totalSupply.mul(1).div(100).mul(5).div(100).mul(reflectionToTokenConversionRate), // Contract owns 1% * 5% of reflection supply after transfer (as liquidity tax)
					totalReflectionSupply, 
					expectedRedistributedToken.mul(reflectionToTokenConversionRate), 
					totalSupply
				)
			);
		});

		it("Token contract should swap and liquidify once it owns more than 0.05% of total token supply", async function() {
			// Get signers
			const signers = await ethers.getSigners();
			// Get initial liquidity in the swap
			const pancakeSwapProxyAddress = await TDMToken.pancakeSwapProxy();
			const pancakeSwapProxy = await ethers.getContractAt("PancakeSwapProxy", pancakeSwapProxyAddress, signers[1]);
			const lpTokenAddress = await pancakeSwapProxy.pancakeswapV2Pair();
			const lpTokenContract = new ethers.Contract(lpTokenAddress, JSON.parse(fs.readFileSync("./test/PancakePair_ABI.json")), signers[1]);
			const lpTokenReservesInitial = await getReserves(lpTokenContract);
			// Get initial LP token balance of owner
			const lpTokenOwnerBalanceInitial = await lpTokenContract.balanceOf(signers[0].address);
			// Get initial total token and reflection supply, and compute their ratio
			const totalSupply = await TDMToken.totalSupply();
			// Transferring 0.05% of total supply from signers[1] to the contract
			const TDMTokenSignerOne = getTDMContract(TDMToken, signers[1]);
			await TDMTokenSignerOne.transfer(TDMToken.address, totalSupply.mul(5).div(10000));
			// Next transaction should trigger a swap and liquidify event and provide liquidity to the swap
			await TDMTokenSignerOne.transfer(signers[11].address, 1);
			// Check if more TDM is now in the swap
			// Note that we will not get more BUSD in the swap since we are simply swapping TDM with BUSD and then providing it back to the swap
			const lpTokenReservesAfter = await getReserves(lpTokenContract);
			expect(lpTokenReservesAfter[0].gt(lpTokenReservesInitial[0])); // Expect more TDM to be in the pool
			expect(lpTokenReservesAfter[1]).to.equal(lpTokenReservesInitial[1]); // Expect same amount of BUSD in the pool
			// Check if the newly minted LP token is sent to the owner
			const lpTokenOwnerBalanceAfter = await lpTokenContract.balanceOf(signers[0].address);
			expect(lpTokenOwnerBalanceAfter).gt(lpTokenOwnerBalanceInitial); // Expect owner to have more LP token now since the newly minted LP token should be sent to the owner
		});

		it("Token contract should swap and liquidify normally even when it owns more _maxTxAmount and is excluded from reflection reward", async function() {
			// Get signers
			const signers = await ethers.getSigners();
			// Get initial liquidity in the swap
			const pancakeSwapProxyAddress = await TDMToken.pancakeSwapProxy();
			const pancakeSwapProxy = await ethers.getContractAt("PancakeSwapProxy", pancakeSwapProxyAddress, signers[1]);
			const lpTokenAddress = await pancakeSwapProxy.pancakeswapV2Pair();
			const lpTokenContract = new ethers.Contract(lpTokenAddress, JSON.parse(fs.readFileSync("./test/PancakePair_ABI.json")), signers[1]);
			const lpTokenReservesInitial = await getReserves(lpTokenContract);
			// Exclude contract address from reflection reward
			await TDMToken.excludeFromReward(TDMToken.address);
			// Transferring _maxTxAmount + 1 from signers[1] to the contract
			const TDMTokenSignerOne = getTDMContract(TDMToken, signers[1]);
			const maxTxAmount = await TDMTokenSignerOne._maxTxAmount();
			await TDMToken.transfer(TDMToken.address, maxTxAmount.add(1)); // Only owner can transfer over the transaction limit
			// Next transaction should trigger a swap and liquidify event and provide liquidity to the swap
			await TDMTokenSignerOne.transfer(signers[11].address, 1);
			// Check if more TDM is now in the swap
			// Note that we will not get more BUSD in the swap since we are simply swapping TDM with BUSD and then providing it back to the swap
			const lpTokenReservesAfter = await getReserves(lpTokenContract);
			expect(lpTokenReservesAfter[0].gt(lpTokenReservesInitial[0])); // Expect more TDM to be in the pool
			expect(lpTokenReservesAfter[1]).to.equal(lpTokenReservesInitial[1]); // Expect same amount of BUSD in the pool
		});

		it("Token contract should not swap and liquidify if sender is Pancakeswap Pair even if it owns more than 0.05% of total token supply", async function() {
			// Get signers
			const signers = await ethers.getSigners();
			// Get initial liquidity in the swap
			const pancakeSwapProxyAddress = await TDMToken.pancakeSwapProxy();
			const pancakeSwapProxy = await ethers.getContractAt("PancakeSwapProxy", pancakeSwapProxyAddress, signers[1]);
			const lpTokenAddress = await pancakeSwapProxy.pancakeswapV2Pair();
			const lpTokenContract = new ethers.Contract(lpTokenAddress, JSON.parse(fs.readFileSync("./test/PancakePair_ABI.json")), signers[1]);
			const lpTokenReservesInitial = await getReserves(lpTokenContract);
			// Get initial total token and reflection supply, and compute their ratio
			const totalSupply = await TDMToken.totalSupply();
			// Transferring 0.05% of total supply from signers[1] to the contract
			const TDMTokenSignerOne = getTDMContract(TDMToken, signers[1]);
			await TDMTokenSignerOne.transfer(TDMToken.address, totalSupply.mul(5).div(10000));
			// Buying token from the swap should not trigger a swap
			const pancakeswapRouterPurchaser = getPancakeswapRouterContract(signers[11]);
			const BUSDPurchaser = getBUSDContract(signers[11]);
			await BUSDPurchaser.approve(PancakeswapRouterAddress, toBUSD(1));
			await pancakeswapRouterPurchaser.swapExactTokensForTokensSupportingFeeOnTransferTokens(
				toBUSD(1),
				0,
				[ BUSDPurchaser.address, TDMToken.address ],
				signers[11].address,
				Date.now()+100000
			);
			// Less TDM should be in the swap now since no swap and liquidify event should have been triggered
			const lpTokenReservesAfter = await getReserves(lpTokenContract);
			expect(lpTokenReservesAfter[0].lt(lpTokenReservesInitial[0])); // Expect less TDM to be in the pool
			expect(lpTokenReservesAfter[1].gt(lpTokenReservesInitial[1])); // Expect more BUSD in the pool
		});

		it("Token contract should swap and liquidify normally if selling TDM token to Pancakeswap if it owns more than 0.05% of total token supply", async function() {
			// Get signers
			const signers = await ethers.getSigners();
			// Get initial liquidity in the swap
			const pancakeSwapProxyAddress = await TDMToken.pancakeSwapProxy();
			const pancakeSwapProxy = await ethers.getContractAt("PancakeSwapProxy", pancakeSwapProxyAddress, signers[1]);
			const lpTokenAddress = await pancakeSwapProxy.pancakeswapV2Pair();
			const lpTokenContract = new ethers.Contract(lpTokenAddress, JSON.parse(fs.readFileSync("./test/PancakePair_ABI.json")), signers[1]);
			const lpTokenReservesInitial = await getReserves(lpTokenContract);
			// Get initial total token and reflection supply, and compute their ratio
			const totalSupply = await TDMToken.totalSupply();
			// Transferring 0.05% of total supply from signers[1] to the contract
			const TDMTokenSignerOne = getTDMContract(TDMToken, signers[1]);
			await TDMTokenSignerOne.transfer(TDMToken.address, totalSupply.mul(5).div(10000));
			// Selling a token should trigger a swap and liquidify event
			const pancakeswapRouterSeller = getPancakeswapRouterContract(signers[1]);
			const BUSDSeller = getBUSDContract(signers[1]);
			await TDMTokenSignerOne.approve(PancakeswapRouterAddress, 1); // Sell 1 token via Pancakeswap
			await pancakeswapRouterSeller.swapExactTokensForTokensSupportingFeeOnTransferTokens(
				1,
				0,
				[ TDMToken.address, BUSDSeller.address ],
				signers[1].address,
				Date.now()+100000
			);
			// Check if more TDM is now in the swap since a swap and liquidify event should have been triggered
			// Less BUSD should also be in the swap now due to the selling of 1 TDM token
			const lpTokenReservesAfter = await getReserves(lpTokenContract);
			expect(lpTokenReservesAfter[0].gt(lpTokenReservesInitial[0]));
			expect(lpTokenReservesAfter[1].lt(lpTokenReservesInitial[1]));
		});

	});
	
});