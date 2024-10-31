// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Pool} from "../src/Pool.sol";
import {Token} from "./mocks/Token.sol";
import {Auction} from "../src/Auction.sol";
import {Utils} from "../src/lib/Utils.sol";
import {BondToken} from "../src/BondToken.sol";
import {Distributor} from "../src/Distributor.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {LeverageToken} from "../src/LeverageToken.sol";
import {TokenDeployer} from "../src/utils/TokenDeployer.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract DistributorTest is Test {
  Distributor public distributor;
  Pool public _pool;
  PoolFactory.PoolParams private params;
  PoolFactory public poolFactory;

  address public user = address(0x1);
  address public sharesTokenOwner = address(0x2);
  address private deployer = address(0x3);
  address private minter = address(0x4);
  address private governance = address(0x5);

  address public constant ethPriceFeed = address(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70);

  function setUp() public {
    vm.startPrank(deployer);

    // TokenDeployer deploy
    address tokenDeployer = address(new TokenDeployer());

    // Distributor deploy
    distributor = Distributor(Utils.deploy(address(new Distributor()), abi.encodeCall(Distributor.initialize, (governance))));

    // Pool, Bond & Leverage Beacon deploy
    address poolBeacon = address(new UpgradeableBeacon(address(new Pool()), governance));
    address bondBeacon = address(new UpgradeableBeacon(address(new BondToken()), governance));
    address levBeacon = address(new UpgradeableBeacon(address(new LeverageToken()), governance));

    // PoolFactory deploy
    poolFactory = PoolFactory(Utils.deploy(address(new PoolFactory()), abi.encodeCall(
      PoolFactory.initialize, 
      (governance,tokenDeployer, address(distributor), ethPriceFeed, poolBeacon, bondBeacon, levBeacon)
    )));

    vm.stopPrank();

    vm.startPrank(governance);
    distributor.grantRole(distributor.POOL_FACTORY_ROLE(), address(poolFactory));

    params.fee = 0;
    params.sharesPerToken = 50*10**6;
    params.reserveToken = address(new Token("Wrapped ETH", "WETH", false));
    params.distributionPeriod = 0;
    params.couponToken = address(new Token("Circle USD", "USDC", false));
    
    vm.stopPrank(); 
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    // Mint reserve tokens
    rToken.mint(governance, 10000000000);
    rToken.approve(address(poolFactory), 10000000000);

    // Create pool and approve deposit amount
    _pool = Pool(poolFactory.createPool(params, 10000000000, 10000*10**18, 10000*10**18, "", "", "", ""));

    _pool.bondToken().grantRole(_pool.bondToken().DISTRIBUTOR_ROLE(), governance);
    _pool.bondToken().grantRole(_pool.bondToken().DISTRIBUTOR_ROLE(), address(distributor));
    _pool.bondToken().grantRole(_pool.bondToken().MINTER_ROLE(), minter);
    _pool.lToken().grantRole(_pool.lToken().MINTER_ROLE(), minter);
  }

  function fakeSucceededAuction(address poolAddress, uint256 period) public {
    address auction = address(new Auction(params.couponToken, params.reserveToken, 1000000000000, block.timestamp + 10 days, 1000, address(0)));

    uint256 auctionSlot = 11;
    bytes32 auctionPeriodSlot = keccak256(abi.encode(period, auctionSlot));
    vm.store(address(poolAddress), auctionPeriodSlot, bytes32(uint256(uint160(auction))));

    uint256 stateSlot = 6;
    vm.store(auction, bytes32(stateSlot), bytes32(uint256(1)));
  }

  function testClaimShares() public {
    Token sharesToken = Token(_pool.couponToken());

    vm.startPrank(minter);
    _pool.bondToken().mint(user, 1*10**18);
    sharesToken.mint(address(_pool), 50*(1+10000)*10**18);
    vm.stopPrank();

    vm.startPrank(governance);
    fakeSucceededAuction(address(_pool), 0);
    _pool.distribute();
    vm.stopPrank();

    vm.startPrank(user);

    vm.expectEmit(true, true, true, true);
    emit Distributor.ClaimedShares(user, 1, 50*10**18);

    distributor.claim(address(_pool));
    assertEq(sharesToken.balanceOf(user), 50*10**18);
    vm.stopPrank();
  }

  function testClaimSharesDifferentDecimals() public {
    vm.startPrank(governance);

    PoolFactory.PoolParams memory poolParams = PoolFactory.PoolParams({
      fee: 0,
      feeBeneficiary: address(0x1),
      sharesPerToken: 50*10**6,
      reserveToken: address(new Token("Wrapped ETH", "WETH", false)),
      distributionPeriod: 0,
      couponToken: address(new Token("Circle USD", "USDC", false))
    });

    uint8 couponDecimals = 6;
    Token sharesToken = Token(poolParams.couponToken);
    sharesToken.setDecimals(couponDecimals);

    Token rToken = Token(poolParams.reserveToken);

    // Mint reserve tokens
    rToken.mint(governance, 10000000000);
    rToken.approve(address(poolFactory), 10000000000);

    // Create pool and approve deposit amount
    Pool pool = Pool(poolFactory.createPool(poolParams, 10000000000, 10000*10**18, 10000*10**18, "", "", "", ""));

    pool.bondToken().grantRole(pool.bondToken().DISTRIBUTOR_ROLE(), address(distributor));
    pool.bondToken().grantRole(pool.bondToken().MINTER_ROLE(), minter);
    pool.lToken().grantRole(pool.lToken().MINTER_ROLE(), minter);

    vm.stopPrank();

    vm.startPrank(minter);
    pool.bondToken().mint(user, 1*10**18);
    
    sharesToken.mint(address(pool), 50*(1+10000)*10**6);
    vm.stopPrank();

    vm.startPrank(governance);
    fakeSucceededAuction(address(pool), 0);
    pool.distribute();
    vm.stopPrank();

    vm.startPrank(user);

    vm.expectEmit(true, true, true, true);
    emit Distributor.ClaimedShares(user, 1, 50*10**6);

    distributor.claim(address(pool));
    assertEq(sharesToken.balanceOf(user), 50*10**6);
    
    vm.stopPrank();
  }

  function testClaimNonExistentPool() public {
    vm.startPrank(user);
    vm.expectRevert(Distributor.UnsupportedPool.selector);
    distributor.claim(address(0));
    vm.stopPrank();
  }

  function testClaimAfterMultiplePeriods() public {
    Token sharesToken = Token(_pool.couponToken());

    vm.startPrank(minter);
    _pool.bondToken().mint(user, 1000*10**18);
    sharesToken.mint(address(_pool), (3 * (params.sharesPerToken * 1000 + params.sharesPerToken * 10000) / 10**_pool.bondToken().SHARES_DECIMALS()) * 10**sharesToken.decimals()); //instantiate value + minted value right above
    vm.stopPrank();

    vm.startPrank(governance);
    fakeSucceededAuction(address(_pool), 0);
    fakeSucceededAuction(address(_pool), 1);
    fakeSucceededAuction(address(_pool), 2);

    _pool.distribute();
    _pool.distribute();
    _pool.distribute();
    vm.stopPrank();

    vm.startPrank(user);

    distributor.claim(address(_pool));
    vm.stopPrank();

    assertEq(sharesToken.balanceOf(user), 3 * (50 * 1000) * 10**sharesToken.decimals());
  }

  function testClaimNotEnoughSharesToDistribute() public {
    Token sharesToken = Token(_pool.couponToken());

    vm.startPrank(minter);
    _pool.bondToken().mint(user, 1*10**18);
    // Mint enough shares but don't allocate them
    sharesToken.mint(address(distributor), 50*10**sharesToken.decimals());
    vm.stopPrank();

    //this would never happen in production
    vm.startPrank(governance);
    _pool.bondToken().increaseIndexedAssetPeriod(1);
    vm.stopPrank();

    vm.startPrank(user);
    vm.expectRevert(Distributor.NotEnoughSharesToDistribute.selector);
    distributor.claim(address(_pool));
    vm.stopPrank();
  }

  function testClaimNotEnoughDistributorBalance() public {
    Token sharesToken = Token(_pool.couponToken());

    vm.startPrank(minter);
    _pool.bondToken().mint(user, 1000*10**18);
    // Mint shares but transfer them away from the distributor
    sharesToken.mint(address(distributor), 50*10**18);
    vm.stopPrank();

    vm.startPrank(address(distributor));
    sharesToken.transfer(address(0x1), 50*10**18);
    vm.stopPrank();

    //this would never happen in production
    vm.startPrank(governance);
    _pool.bondToken().increaseIndexedAssetPeriod(1);
    vm.stopPrank();

    vm.startPrank(user);
    vm.expectRevert(Distributor.NotEnoughSharesBalance.selector);
    distributor.claim(address(_pool));
    vm.stopPrank();
  }

  function testAllocateInvalidPoolAddress() public {
    vm.expectRevert("Caller must be a registered pool");
    distributor.allocate(address(0), 100);
  }

  function testAllocateCallerNotPool() public {
    vm.startPrank(user);
    vm.expectRevert("Caller must be a registered pool");
    distributor.allocate(address(_pool), 100);
    vm.stopPrank();
  }

  function testAllocateNotEnoughCouponBalance() public {
    uint256 allocateAmount = 100*10**18;

    vm.startPrank(address(_pool));
    vm.expectRevert(Distributor.NotEnoughCouponBalance.selector);
    distributor.allocate(address(_pool), allocateAmount);
    vm.stopPrank();
  }
}
