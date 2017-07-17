// Lending.sol
// Copyright (C) 2017 Juanjo Alvarez Martinez

//This program is free software: you can redistribute it and/or modify
//it under the terms of the GNU General Public License as published by
//the Free Software Foundation, either version 3 of the License, or
//(at your option) any later version.

//This program is distributed in the hope that it will be useful,
//but WITHOUT ANY WARRANTY; without even the implied warranty of
//MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//GNU General Public License for more details.

//You should have received a copy of the GNU General Public License
//along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity^0.4.8;

// TODO refinancing (increase in leftPayments, change in amount). Must be signed
// by 4/5 of all lenders and the solicitor.

// TODO move LendRequest to its own Contract and InProgressLend members to
// main.

// TODO: amount-default (solicitor sent less money than required by
// amountRequested / numPayments)

contract Lend {
    // ~~~~~~~~~~~~~ constants  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    uint constant secondsPerDay = 3600; // TODO: leap seconds? check the time functions...
    uint constant minSecondsBetweenPayments = 1 * secondsPerDay;
    // ~~~~~~~~~~~~~ data types ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

    // This is a request for a lend. It can be browsed by any potential Lender.
    struct LendRequest {
        // The requested amount that the solicitor would inmediately get from the lenders
        // if the Lend is approved
        uint amountRequested;
        // The total returned amount
        uint amountReturned;
        // The number of payments that the solicitor want to pay
        uint32 numPayments;
        // Time between payments
        uint64 secondsBetweenPayments;
        uint increasePerDayOfDelay;

        string purpose;

        // Amount aproved by the lenders. When this is greated than
        // amountRequested the LendRequest will close and the InProgressLend
        // will start. Then any potential lenders with an Lender.approved =
        // false will be returned their Lender.amount and removed from
        // this.Lenders.
        uint totalAmountLocked;
    }

    struct InProgressLend {
        uint pendingAmount;
        uint amountPerPayment;
        uint64 lastPaymentTstamp;
        uint64 secondsBetweenPayments;

        // If the solicitor delays a payment or sent less than the expected
        // amount, this is the interest that will be used to increase the
        // amount per hour. This interest is calculated from the pending
        // payment amount, not the total, but it will be added to the total and
        // thus leftPayments could be increased). 

        // If the solicitor sends part or a total of the pending amount (with
        // or without the increased interest) it will not change the last/next
        // payment dates.
        uint increasePerDayOfDelay;
        uint totalDefaultsIncrease;
    }

    // When a lender approves the lend, the amountLended goes from this.totalLocked
    // to this.totalApproved. When totalApproved >= LendRequest.amount, the Lend is approved
    // and any Lenders that have not signed are removed and their amount returned.
    struct Lender {
        address lender;
        uint _amount;
        bool approved = false;
    }

    // ~~~~~~~~~~~~~ data members ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ 

    address public solicitor
    mapping (address => Lender) lenders;
    // because you can't really iterate a map in Solidity we need this 
    // (iterable, yay!) list with the same addresses.
    address[] lendersAddrs;

    // This is initially filled. Once enough lenders have signed and the status has 
    // changed to InProgress, the lendRequest will be converted into the approvedLend.
    LendRequest public lendRequest;
    InProgressLend public inProgressLend;

    enum LendStatus = {Requested, Denied, InProgress, Paid}
    LendStatus status = LendStatus.Requested;

    event LogLenderNew(address lenderAddress);
    event LogLenderAddedAmount(address lenderAddress, uint _amount);
    event LogLenderRetiredAmount(address lenderAddress, uint _amount);
    event LogLenderRetire(address lenderAddress);
    event LogLendActivated(address _solicitor, uint _amount);
    event LogLendPayment(address _solicitor, uint _amount);
    event LogLenderReceivedPayment(address lender, uint _amount);
    event LogLendPaid();

    // ~~~~~~~~~~~~~ methods ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

    // Constructor
    function Lend(uint amountRequested, uint amountReturned, uint32 numPayments, 
                  uint64 secondsBetweenPayments, string purpose) {
        require(msg.value == 0);
        require(status == LendStatus.Requested);
        require(amountRequested > 0);
        require(amountReturned > 0);
        require(amountReturned >= amountRequested);
        require(numPayments > 0);
        require(secondsBetweenPayments >= minSecondsBetweenPayments);
        require(purpose.length > 200); 

        solicitor = msg.sender;
        lendRequest.amountRequested = amountRequested;
        lendRequest.amountReturned = amountReturned;
        lendRequest.numPayments = numPayments;
        lendRequest.secondsBetweenPayments = secondsBetweenPayments;
        lendRequest.purpose = purpose;
    }

    function lenderJoin() public {
        require(status == LendStatus.Requested);
        require(lenders[msg.sender] == address(0x0));

        Lender l = Lender({
            lender   : msg.sender,
            _amount  : msg.value,
            approved : false
        });
        lenders[msg.sender] = l;
        lendersAddrs.push(l);
        LogLenderNew(msg.sender);
    }

    function lenderAddAmount() public returns(uint) {
        Lender l = lenders[msg.sender];

        // Must be already a lender:
        require(l.address != address(0x0));
        // Can't add funds to an InProgress, Denied or Finished lend:
        require(status == LendStatus.Requested);
        // Can't add once the lender has approved the request
        require(!lenders[msg.sender].approved);

        l.amount += msg.value;
        LogLenderAddedAmount(msg.sender, msg.value);
        return l.amount;
    }

    function lenderRetireAmount(uint _amount) public returns (uint){
        Lender l = lenders[msg.sender];

        // Must be already a lender:
        require(l.lender != address(0x0));
        // Can't add funds to an InProgress, Denied or Finished lend:
        require(status == LendStatus.Requested);
        // Can't retire funds if the lender has approved the request
        require(!l.approved);
        require(_amount <= l.amount)
        // Can't retire all the funds (that's what lenderRetire is for, not 
        // calling it automatically to avoid accidental retirements)
        require(msg.value > l._amount);

        l.amount -= _amount;
        if (!msg.sender.send(_amount)) {
            l.amount += _amount;
            throw;
        }
        LogLenderRetiredAmount(msg.sender, _amount);
        return l.amount;
    }

    function lenderRetire() public {
        Lender l = lenders[msg.sender];

        require(l.address != address(0x0));
        // Can't retire after the lending has been aproved (lenders that didn't
        // approve the lend are automatically retired when the lending starts)
        require(status != LendStatus.Requested);

        if (!msg.sender.send(l._amount)) {
           throw;
        }

        if (l.approved) {
            l.approved = false;
            lendRequest.totalAmountLocked -= l._amount;
        }

        // TEST: test that this really works
        for (uint i = 0; i < lenderAddrs.length; i++) {
            if (lenderAddrs[i] == msg.sender) {
                delete lenderAddrs[i];
            }
        }
        delete lenders[msg.sender];
        LogLenderRetire(msg.sender);
    }

    function lendActivate() private {
        require(status == LendStatus.Requested);

        // Remove lenders that didn't approve
        for (uint i = 0; i < lendersAddrs.length; i++) {
            if (!lenders[lendersAddrs[i]].approved) {
                lenderRetire(msg.sender);
            }
        }

        status = LendStatus.InProgress;
        solicitor.send(this.amount);
        lendRequest.totalAmountLocked = 0;
        LogLendActivated(address _solicitor, this.amount);
    }

    function lenderApprove() {
        require(status == LendStatus.Requested);

        Lender l = lenders[msg.sender];

        require(l.address != address(0x0));
        require(!l.approved);

        l.approved = true;
        uint neededToStart = lendRequest.amountRequested - lendRequest.totalAmountLocked;
        if (l._amount >= neededToStart) {
            // Return the entra money
            uint extra = l._amount - neededToStart;
            if (extra) {
                l._amount -= extra;
                if (!msg.sender.send(extra)) {
                    l._amount += extra;
                    l.approved = false;
                    throw;
                }
            }
            // Go!
            lendActivate();
        } else {
            // Still not enough to start
            lendRequest.totalAmountLocked += l._amount;
        }
    }

    function lendPaid() private {
        require(status == LendStatus.InProgress);

        status = LendStatus.Paid;
        LogLendPaid();
    }

    function lendersReceivePayment(uint _amount) {
        for (uint i = 0; i < lenderAddrs.length; i++) {
            Lender l = lenderAddrs[i];

            uint part = _amount * (l._amount / amountRequested);
            l.lender.send(part);
            LogLenderReceivedPayment(l.lender, part);
        }
    }

    function receivePayment() public {
        require(status == LendStatus.InProgress);
        require(msg.sender == solicitor);

        // Check if there is a delay-default
        uint currentTStamp = block.timestamp;
        uint secsSinceLastPayment = currentTStamp - inProgressLend.lastPaymentTstamp;
        if (secsSinceLastPayment > secondsBetweenPayments) {
            // there is: increase the pending amount
            delay = secsSinceLastPayment - secondsBetweenPayments;
            increase = (delay / 3600) * increasePerDayOfDelay;
            pendingAmount += increase;
            totalDefaultsIncrease += increase;
        }

        LogLendPayment(msg.sender, msg.value);

        if (msg.value > pendingAmount) {
            // Lend is fully paid, return any excess to the sender
            uint excess = msg.value - pendingAmount;
            pendingAmount = 0;
            if(excess) {
                if (!msg.sender.send(excess)) {
                    throw;                   
                }
            }
            lendPaid();
        }

        pendingAmount -= msg.value;
        inProgressLend.lastPaymentTstamp = currentTStamp;
        lendersReceivePayment(msg.value);
    }

    // Fallback function
    function () {
        throw;
    }
}
