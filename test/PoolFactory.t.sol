// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Pool} from "../src/pools/Pool.sol";
import {PoolFactory} from "../src/pools/PoolFactory.sol";
import {TestToken} from "../src/TestToken.sol";
import {Escrow} from "../src/Escrow.sol";

contract PoolFactoryTest is Test {
    PoolFactory internal factory;
    TestToken internal token;
    Escrow internal escrow;
    address internal owner = address(0xA11CE);

    function setUp() public {
        factory = new PoolFactory();
        token = new TestToken();
        escrow = new Escrow(address(0), address(0), address(0), address(0), address(0));
    }

    function test_createPool_sameCodehashDifferentParams() public {
        address[] memory a = new address[](1);
        a[0] = address(0xC0);
        address[] memory b = new address[](0);
        address p1 = factory.createPool(owner, address(token), address(escrow), a);
        address p2 = factory.createPool(address(0xB0B), address(token), address(escrow), b);
        assertTrue(p1 != p2);
        assertEq(p1.codehash, p2.codehash);
        assertEq(p1.codehash, factory.officialCodehash());
        assertTrue(factory.isOfficial(p1));
        assertTrue(factory.isOfficial(p2));
        assertEq(Pool(p1).owner(), owner);
        assertEq(Pool(p2).owner(), address(0xB0B));
        assertTrue(Pool(p1).controllers(address(0xC0)));
        assertFalse(Pool(p2).controllers(address(0xC0)));
    }

    function test_initialize_cannotRepeat() public {
        address[] memory cs = new address[](0);
        address p = factory.createPool(owner, address(token), address(escrow), cs);
        vm.expectRevert(Pool.AlreadyInitialized.selector);
        Pool(p).initialize(owner, address(token), address(escrow), cs);
    }

    function test_implementation_cannotInitialize() public {
        address[] memory cs = new address[](0);
        address impl = factory.implementation();
        vm.expectRevert(Pool.AlreadyInitialized.selector);
        Pool(impl).initialize(owner, address(token), address(escrow), cs);
    }

    function test_rawPool_isNotOfficial() public {
        assertFalse(factory.isOfficial(address(new Pool())));
    }
}
