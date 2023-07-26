// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC721 {
    function transferFrom(address _from, address _to, uint _nftId) external;
    function ownerOf(uint _nftId) external view returns (address);
}

contract NFTLoanContract {
    address payable public owner;
    uint256 public loanDurationInDays = 30 days;
    uint256 public inReview = 7 days;

    enum LoanStatus { isOpen, inReview, isApproved, isPaid, isClosed }

    struct Loan {
        string loanTitle;
        string NFTDetails;
        IERC721 nft;
        uint256 nftId;
        uint256 loanDuration;
        uint256 interestRate;
        uint256 collateral;
        uint256 loanAmount;
        address payable borrower;
        uint256 approvedAt;
        uint256 requestedAt;
        LoanStatus status;
    }

    mapping(uint256 => Loan) public loans;
    uint256 public loanCounter;
    uint256 private constant MAX_LOAN_LIMIT = 100; 

    constructor() {
        owner = payable(msg.sender);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not Authorized");
        _;
    }

    modifier loanExists(uint256 loanId) {
        require(loans[loanId].status != LoanStatus.isClosed, "Loan does not exist or has been closed");
        _;
    }

    function createNFTLoan(
        string memory _loanTitle,
        string memory _NFTDetails,
        address _nft,
        uint256 _nftId,
        uint256 _interestRate,
        uint256 _collateral
    ) public onlyOwner {
        require(loanCounter < MAX_LOAN_LIMIT, "Loan limit reached");
        
        loans[loanCounter] = Loan(
            _loanTitle,
            _NFTDetails,
            IERC721(_nft),
            _nftId,
            loanDurationInDays,
            _interestRate,
            _collateral,
            0,
            payable(owner),
            0,
            0,
            LoanStatus.isOpen
        );

        loanCounter++;

        require(loans[loanCounter - 1].nft.ownerOf(_nftId) == msg.sender, "Only owned NFTs can be loaned");
    }

    function requestLoan(uint256 _loanId) public payable loanExists(_loanId) {
        Loan storage loan = loans[_loanId];
        require(msg.value >= loan.collateral * 1 ether, "Provide more collateral");
        require(loan.borrower == owner && loan.borrower != msg.sender, "Loan already approved or not available");
        loan.loanAmount = loan.collateral * 1 ether;
        loan.borrower = payable(msg.sender);
        loan.status = LoanStatus.inReview;
        loan.requestedAt = block.timestamp;

         // Check if the loan request is within the inReview duration
        if (block.timestamp >= loan.requestedAt + inReview && loan.status == LoanStatus.inReview) {
            // If the loan request is not approved within the loan duration,
            // transfer the collateral back to the borrower

            (bool success, ) = payable(loan.borrower).call{value: loan.loanAmount}("");
            require(success, "Transfer failed");
            loan.borrower = owner;
            loan.status = LoanStatus.isOpen;
            loan.loanAmount = 0;
            loan.requestedAt = 0;
        }
    }

    function reclaimCollateral(uint256 _loanId) public loanExists(_loanId) {
        Loan storage loan = loans[_loanId];
        require(loan.status == LoanStatus.inReview, "Loan is not under review");
        require(msg.sender == loan.borrower, "Only the borrower can reclaim collateral");

        // Transfer the collateral amount back to the borrower
        (bool success, ) = payable(loan.borrower).call{value: loan.collateral * 1 ether}("");
        require(success, "Transfer failed");
        loan.status = LoanStatus.isOpen;
        loan.borrower = owner;
        loan.loanAmount = 0;
        loan.requestedAt = 0;
    }

    function approveLoan(uint256 _loanId) public onlyOwner loanExists(_loanId) {
        Loan storage loan = loans[_loanId];
        require(loan.status == LoanStatus.inReview, "Loan is not under review");
        require(loan.loanAmount <= loan.collateral * 1 ether, "Collateral not met");

        loan.nft.transferFrom(owner, loan.borrower, loan.nftId);

        loan.approvedAt = block.timestamp;
        loan.status = LoanStatus.isApproved;

        if (block.timestamp >= loan.approvedAt + loanDurationInDays && loan.status == LoanStatus.isApproved) {
            // If the loan is not repaid within the loan duration,
            // transfer the collateral back to the lender
            (bool refundSuccess, ) = payable(owner).call{value: loan.collateral * 1 ether}("");
            require(refundSuccess, "Collateral refund failed");
            loan.status = LoanStatus.isOpen;
        }
    }


    function closeLoan(uint256 _loanId) public onlyOwner loanExists(_loanId) {
        Loan storage loan = loans[_loanId];
        require(loan.status == LoanStatus.isPaid, "Not Paid");
        

        // Transfer the loan amount to the contract owner
        (bool success, ) = payable(owner).call{value: loan.loanAmount}("");
        require(success, "Transfer failed");
        loan.status = LoanStatus.isClosed;
    }

    function repayLoan(uint256 _loanId) public payable loanExists(_loanId) {
        Loan storage loan = loans[_loanId];
        require(loan.status == LoanStatus.isApproved, "Not Approved");
        require(block.timestamp <= loan.approvedAt + loan.loanDuration, "Loan duration exceeded");
        require(msg.sender == loan.borrower, "Not Borrower");
        uint256 timeElapsed = block.timestamp - loan.approvedAt;
        uint256 interest_ = (loan.interestRate * timeElapsed) / (loanDurationInDays); // 5% monthly
        uint256 amount = interest_ * 1 ether;

        require(msg.value >= amount, "Incorrect loan amount");
        loan.nft.transferFrom(loan.borrower, owner, loan.nftId);
        (bool success, ) = payable(loan.borrower).call{value: loan.collateral * 1 ether}("");
        require(success, "Transfer failed");
        loan.loanAmount = amount;
        loan.borrower = owner;
        loan.status = LoanStatus.isPaid;
    }

    function getOngoingLoans() public view returns (Loan[] memory) {
        uint256 countOngoingLoans = 0;
        for (uint256 i = 0; i < loanCounter; i++) {
            if (loans[i].status == LoanStatus.isOpen) {
                countOngoingLoans++;
            }
        }

        Loan[] memory ongoingLoans = new Loan[](countOngoingLoans);
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < loanCounter; i++) {
            if (loans[i].status == LoanStatus.isOpen) {
                ongoingLoans[currentIndex] = loans[i];
                currentIndex++;
            }
        }
        return ongoingLoans;
    }

    function getLoanDetails(uint256 _loanId) public view returns (Loan memory) {
        return loans[_loanId];
    }

    function getInterest(uint256 _loanId) public view returns(uint256) {
        Loan storage loan = loans[_loanId];
        require(loan.status == LoanStatus.isApproved, "Not Approved");
        require(block.timestamp <= loan.approvedAt + (loan.loanDuration * 1 days), "Loan duration exceeded");
        require(msg.sender == loan.borrower, "Not Borrower");
        uint256 timeElapsed = block.timestamp - loan.approvedAt;
        uint256 interest_ = (loan.interestRate * timeElapsed) / (loanDurationInDays); // 5% monthly
        return interest_ * 1 ether;
    }
}
