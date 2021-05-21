// Require the Hardhat Runtime Environment explicitly
const hre = require("hardhat");

// Deployment script
async function main() {
	// Compile smart contracts
	await hre.run('compile');
	// Get the contract to deploy
	const Methane = await hre.ethers.getContractFactory("Methane");
	const methane = await Methane.deploy();
	// Wait for the contract to be deployed
	await methane.deployed();
	// Deployment message
	console.log("Methane deployed to:", methane.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
	.then(() => process.exit(0))
	.catch(error => {
		console.error(error);
		process.exit(1);
	});
