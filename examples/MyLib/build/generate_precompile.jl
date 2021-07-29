using MyLib

function count_to_ten()
    count = zero(Int32)
    while count < 10
        count = increment32(count)
    end
end

count_to_ten()
