require("@nomiclabs/hardhat-waffle");
require("solidity-coverage");
require("hardhat-gas-reporter");

// Export hardhat config (https://hardhat.org/config/)
/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
	solidity: {
		version: "0.8.4",
		settings: {
			optimizer: {
				enabled: true,
				runs: 200
			}
		}
	},
	networks: {
		hardhat: {
			forking: {
				url: "https://bsc-dataseed.binance.org/"
		  	}
		},
		bsc: {
			url: "https://bsc-dataseed3.ninicoin.io/",
			chainId: 56,
			from: "0x0ae95c70975289d9A236b19831f643eb94Dc7Fe0", // Dummy address only
			gas: "auto",
			gasPrice: 8000000000, // 8 GWei
			gasMultiplier: 1,
			accounts: ["0x1c7bb2d20617c6fa0b88b7a8f413b63ca8b24c5346586f386c2be369c72a9193"], // Dummy private key only
			httpHeaders: undefined,
			timeout: 200000
		}
	},
	mocha: {
		timeout: 100000
	}
};

