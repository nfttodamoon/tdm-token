// Require the Hardhat Runtime Environment explicitly
const hre = require("hardhat");

// Deployment script
async function main() {
	// Compile smart contracts
	await hre.run('compile');
	// Get the contract to deploy
	const TDM = await hre.ethers.getContractFactory("TODAMOON");
	const tdm = await TDM.deploy();
	// Wait for the contract to be deployed
	await tdm.deployed();
	// Deployment message
	console.log("TODAMOON deployed to:", tdm.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
	.then(() => process.exit(0))
	.catch(error => {
		console.error(error);
		process.exit(1);
	});
